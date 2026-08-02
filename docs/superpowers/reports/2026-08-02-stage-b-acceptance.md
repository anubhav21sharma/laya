# Stage B Acceptance Checkpoint

Status: **accepted**

Scope: Stage B through Task 7. Stage C has not started.

Base revision: `d537b4366817be177fde550580da340d994d1fac`

## Outcome

Task 7 moves stroke preparation off `MainActor` behind a bounded mailbox and a
long-lived, user-initiated worker. Main now performs bounded input admission and
later composites prepared private surfaces. Stabilization, interpolation,
spacing, dynamics, projection, dirty-region work, scheduling, and private
surface encoding execute in the worker-owned coordinator.

Authoritative input is lossless: capacity failure is typed and atomic.
Prediction has independent bounded storage and may be truncated or replaced
without changing canonical output. A commit is a causal barrier over admitted
authoritative input and submitted prepared surfaces. Cancellation and every
injected failure retire transient ownership before the renderer is reused.

The interactive `MTKView` is demand-driven. It remains paused when there is no
stroke work, pending composite, viewport animation, or HUD sampling.

## Lifecycle and mode matrix

The final focused and broad suites exercise:

- begin, single and batched append, prediction replacement and shedding;
- estimated-property correction, finish, pointer-up, and commit ordering;
- cancel, focus loss, injected failure, rollback, and immediate reuse;
- a rapid next stroke while the preceding workspace retires;
- resize, clear, undo, redo, and brush selection during and between strokes;
- plain documents;
- seamless grid, half-drop, and hexagonal projection; and
- radial rotation and reflection, including orbit coverage and resize/history.

Representative named cases include
`nativeInkOffMainRoutePublishesAfterPreparationAndCommits`,
`nativeInkOffMainPreparationIsBatchPartitionInvariant`,
`predictionReplacementIsBoundedAndNeverRemovesAuthoritativeInput`,
`predictedAwaitingEstimateIsCorrectedWithoutChangingProvenance`,
`commitBarrierWaitsForEveryAuthoritativeFrameToSubmit`,
`cancellationClearsQueuesAndRejectsStaleGeneration`,
`nativeGPUFailureClearsTransientStateAndNextStrokeSucceeds`,
`retiringWorkspaceDefersRapidPointerUntilTrueIdleExactlyOnce`,
`resizeUndoRedoRestoresExactDimensionsBytesAndMonotonicRevision`,
`activeStrokeRetainsBrushAcrossCompilerSelectionChurn`,
`offMainMatchesFrozenPixelsAcrossTilingAndSymmetryWithPrediction`, and
`radialResizeUndoRedoRestoresExactAtlasAndDocumentSize`.

## Production route audit

The app's production input call is the public segmented batch API in
`EditorSessionController`. It supplies an authoritative prefix and a separately
bounded predicted suffix. Production `beginStroke` installs no frozen
scheduler. The array-based batch overload is package-only.

The old `FrameScheduler` construction in `GridRenderer` is confined to
`beginFrozenProjectionHarnessExecution`; its three callers are harness helpers.
No app production caller reaches that entry point, and the source guard
`activeProductionContainsNoLegacyDepositionRuntimeSurface` passes. The new
`StrokeFrameScheduler` is serviced by a detached user-initiated worker and is
not the retired synchronous input route.

## Failure and ownership evidence

Failure injection covers admission, projection capacity, private-surface
reservation and encoding, Main composite preparation, command creation, GPU
completion, revision allocation, and commit. Each case preserves canonical
pixels and history, terminates or acknowledges the prepared-surface lease once,
and permits the next stroke.

The ownership tests cover actor-owned, Main-borrowed, GPU-submitted,
abandoned-before-submission, successful acknowledgement, failure
acknowledgement, and cancellation racing an in-flight acknowledgement.

## Performance checkpoint

The final uncontended focused gate ran:

```text
swift test --filter 'StrokeFrameSchedulerTests|StrokeRenderCoordinatorTests|InteractiveFrameTimestampTests|DepositionRendererTests'
```

Result: **110 tests in 3 suites passed in 6.787 seconds**.

Its accelerated production trace processed 36,000 samples representing ten
logical minutes:

```text
logical_ns=599999976000
wall_ns=4203767292
first_decile_ns_per_event=59424
last_decile_ns_per_event=55146
input_high_water=60 / 12288
input_storage=12294 / 12294
result_high_water=1 / 1
result_storage=1 / 1
workspace_installations=1 / 1
payload_bytes=1540096
surfaces=2
surface_lease_high_water=1
missed=0
deferred=98002
```

The last decile was about 7.2% faster than the first. Queue storage, result
storage, workspace count, payload storage, surface count, and lease occupancy
were flat and bounded. No frame was missed. Deferred submissions are bounded
coalescing decisions, not queue growth or lost authoritative input.

The final optimized allocation probe reported:

```text
ALLOCATOR PROBE SELF-TEST PASS allocations=1
ALLOCATOR PROBE OFF-MAIN PASS application=0 workspace=0 main=0 authoritative=0 estimated=0 prediction=0 packaging=0 surface_driver_mallocs=3408
ALLOCATOR PROBE PRODUCTION PASS allocations=0
```

Metal driver allocations are reported separately; application-side warmed
input and preparation paths remained allocation-free.

## Broad regression checkpoint

The frozen pre-Task-7 baseline contains 1,424 tests in 73 suites with 27 known
brush-quality/evidence issue records. The final tree contains 1,469 tests in 74
suites and the same 27 issue records.

The final issue lines were selected, normalized only for Swift source line and
column movement, sorted, and compared byte-for-byte with the frozen baseline.
`diff` returned `0`. Therefore the broad suite has no added, removed, or changed
issue record.

The broad run's nonzero process status is expected because Swift Testing treats
those frozen 27 issue records as failures. It is not presented as a passing
suite.

## Build and portability gates

All of these final-tree gates exited `0`:

- optimized Swift package build;
- complete strict-concurrency build with warnings as errors;
- macOS app build;
- universal iOS Simulator app build; and
- unsigned generic iOS device app build.

The simulator lacks the physical drawable-presentation callback available on
device. Its command-completion fallback records
`.offscreenCommandCompleted`; it cannot claim `.drawablePresented`. Physical
macOS and iOS paths retain real drawable-presentation telemetry. A structural
regression test enforces this distinction.

No iPad was available for physical-device runtime validation. That does not
invalidate this software checkpoint; the generic device binary compiles and
the remaining physical-device quality/performance observation belongs to the
later manual acceptance pass.

## Evidence logs

- `/tmp/stage-b-final-exact-after-simulator-semantics.log`
- `/tmp/stage-b-acceptance-full-after-simulator-semantics.log`
- `/tmp/stage-b-final-allocation-after-simulator-semantics.log`
- `/tmp/stage-b-final-release-after-simulator-semantics.log`
- `/tmp/stage-b-final-strict-after-simulator-semantics.log`
- `/tmp/stage-b-final-macos-build-after-simulator-semantics.log`
- `/tmp/stage-b-final-ios-simulator-build-semantics-green.log`
- `/tmp/stage-b-final-ios-device-build-semantics-green.log`
- `/tmp/stage-b-final-telemetry-and-route-tests.log`

These logs are local execution evidence and are intentionally not committed.

## Independent review

The final independent review was run after implementation and after correcting
the simulator telemetry fallback. It found no unresolved Critical or Important
issue in the Stage B delta.

## Exit decision

Stage B is accepted. Task 7 is complete, the renderer remains reusable after
failure, production input no longer uses the legacy synchronous renderer, and
the runtime satisfies the bounded-work and bounded-storage gates. Stage C is
deliberately not started by this change.
