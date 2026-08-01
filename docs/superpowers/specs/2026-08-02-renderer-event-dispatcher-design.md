# Renderer Event Dispatcher Design

**Date:** 2026-08-02

**Status:** Approved for implementation

**Parent program:** `docs/superpowers/plans/2026-08-01-brush-engine-corrective-program.md`

## Purpose

`GridRenderer` must never call public observers while a renderer operation is
partially installing, mutating, or tearing down stroke state. All observer
delivery will move behind one main-actor event dispatcher with transactional
publication, generation invalidation, bounded retained storage, and fair,
non-recursive draining.

This is the prerequisite Task 5A for prediction isolation. It replaces the
logical-dab-only publication mechanism added during Task 5 and closes the two
remaining Task 5 review findings:

1. consumed logical-dab entries remain retained for the entire drain; and
2. runtime telemetry callbacks can synchronously re-enter half-installed or
   half-destroyed stroke state.

## Scope

The dispatcher owns delivery of every public `GridRenderer` callback:

- `onError`
- `onIdleStateChange`
- `onOperationCompleted`
- `onLogicalDabsGenerated`
- `onStrokeRuntimeSnapshot`
- `onStrokeRuntimeSegmentMarker`
- debug `onInteractiveFramePresented`
- debug `onInteractiveFrameMetrics`

It does not move renderer mutation off `MainActor`; Task 7 owns that executor
change. It does not change callback payload types, public callback property
signatures, canonical pixels, stroke generation, or operation completion
semantics.

## Invariants

1. **Committed state before observation.** A public observer runs only after
   the operation that produced its event has committed its externally visible
   renderer state or completed its rollback.
2. **No recursive delivery.** A callback may synchronously invoke another
   renderer API, but nested events are queued. Callback stack depth remains
   one.
3. **FIFO within a generation.** Lossless events preserve enqueue order.
4. **Accepted-prefix publication.** In a batch, events belonging to each
   successfully accepted sample become eligible at its checkpoint. A later
   sample failure discards only that sample's uncommitted events.
5. **Stale stroke work never leaks.** Cancel, failure rollback, reset, and a
   replacement stroke invalidate queued stroke-scoped events from the prior
   generation.
6. **No consumed-prefix retention.** Dequeued storage is released or reused
   incrementally; memory depends on live pending events, never the historical
   number delivered in the current drain.
7. **Fair main-actor use.** One drain turn delivers at most 256 callback
   invocations. Remaining work continues in exactly one scheduled
   `Task { @MainActor ... }`, allowing the run loop to service rendering and
   input between turns.
8. **Lossless semantic events.** Errors, idle transitions, operation
   completions, logical dabs, and segment markers are never coalesced or
   dropped.
9. **Telemetry is explicitly coalescible.** Pending runtime snapshots retain
   only the newest snapshot for the same telemetry generation. Debug frame
   metrics and presentation events retain only the newest undelivered value of
   their kind. Coalescing increments diagnostic counters.
10. **No asynchronous mutation.** Scheduled continuation delivers immutable
    events only. It never resumes or completes a renderer transaction.

## Components

### `RendererEvent`

An internal immutable enum carries callback payloads. Every case declares its
delivery policy:

- lossless renderer-scoped control event;
- lossless stroke-generation event; or
- coalescible telemetry-generation event.

Logical dabs may be stored as a contiguous batch plus a delivery cursor. The
public observer still receives one `LogicalDab` per invocation, so the drain
budget counts dabs, not batches.

### `RendererEventDispatcher`

A final `@MainActor` class owns:

- a ring/deque of committed events;
- a separate staging array for the current outer renderer operation;
- the active stroke and telemetry generations;
- operation nesting depth and failure state;
- whether a drain is active or scheduled;
- coalescing and high-water diagnostics.

Its production surface is intentionally small:

```swift
@MainActor
final class RendererEventDispatcher {
    static let deliveryBudgetPerTurn = 256

    func beginOperation()
    func stage(_ event: RendererEvent)
    func commitCheckpoint()
    func endOperation(succeeded: Bool)
    func advanceStrokeGeneration() -> UInt64
    func advanceTelemetryGeneration() -> UInt64
    func invalidateStrokeGeneration(_ generation: UInt64)
    func invalidateTelemetryGeneration(_ generation: UInt64)
}
```

`GridRenderer` supplies a delivery closure that switches over immutable events
and invokes the current public observer property. Observer replacement before
delivery therefore uses the observer installed at delivery time, matching the
existing callback-property model.

### Queue storage

The queue is a true deque/ring or an equivalent implementation that compacts
after at most 256 consumed callback invocations. It must not use an ever-growing
array plus a head index that is cleared only after the whole drain ends.

The queue does not need a hard cap on lossless event count because dropping a
committed semantic event is invalid. Its retained storage is bounded by the
currently pending semantic payload, while consumed storage is reclaimed every
turn. Existing authoritative input and dab budgets remain the producer-side
backpressure. The dispatcher records pending high-water so Task 7 and the
performance gate can detect a producer that outruns delivery.

## Transaction Model

Every public renderer mutation and every main-actor completion handler enters
an event operation:

1. `beginOperation()` establishes the outer transaction. Nested renderer calls
   share the active drain but receive their own staging boundary.
2. Renderer state is prepared and committed without invoking observers.
3. `stage(_:)` records immutable event payloads.
4. A successful sample in `appendStrokeBatch` calls `commitCheckpoint()`.
5. `endOperation(succeeded:)` publishes committed staging or discards the
   current uncommitted suffix after rollback.
6. Only the outermost completed operation requests a drain.

The dispatcher must model nested staging explicitly; a single global failure
flag is insufficient because a callback-triggered nested operation can fail
without retroactively invalidating an already committed outer event.

## Generation Rules

- Beginning a stroke obtains a new nonzero stroke generation after the new
  active stroke is fully installed.
- Logical-dab events use that generation.
- Cancel or failed begin invalidates the installed generation after rollback
  completes.
- A normal finish may publish its final logical dabs and end telemetry marker;
  invalidation happens only after those committed events are queued.
- Starting a replacement stroke advances the generation. Any still-pending
  events from the previous generation are skipped during delivery.
- Enabling, disabling, or reconfiguring telemetry advances the telemetry
  generation. Runtime snapshots and markers from older configurations are
  skipped.
- Generation comparison happens immediately before each callback invocation,
  including each dab inside a batched event.

## Callback Ordering

For one accepted input sample, callback order is:

1. generated logical dabs in ordinal order;
2. runtime segment marker when the sample opens or closes a segment;
3. runtime snapshot representing the state after that marker; and
4. outer operation idle/error/completion events in the order their renderer
   transitions occur.

`configureStrokeRuntimeTelemetry` publishes its initial snapshot only after
the controller and generation are installed. `beginStrokeRuntime` stages its
begin marker and snapshot only after `activeStroke`, generator, buffers, and
coordinator are installed. `endStrokeRuntimeIfPossible` first closes/discards
runtime frames and completes stroke teardown, then stages the final snapshot
and marker.

Command-buffer completion callbacks enqueue events on `MainActor`; they never
invoke public observers directly.

## Fair Drain

Drain is iterative. Each turn:

1. removes the next live event from the deque before invoking its observer;
2. skips stale-generation events;
3. invokes at most 256 callbacks, counting each logical dab separately;
4. compacts/reuses consumed storage before returning; and
5. schedules one continuation if events remain.

If an observer self-feeds input forever, each turn remains bounded in stack,
consumed storage, and CPU time. The callback chain can continue across run-loop
turns without freezing drawing or retaining every consumed event.

## Error And Reset Semantics

- A thrown operation rolls renderer state back first, discards its uncommitted
  staged events, then stages any public error/idle/completion event describing
  the completed rollback.
- An accepted batch prefix is not rolled back because a later sample fails.
- `resetLiveState`, cancel, failed begin, telemetry disable, and resource reset
  invalidate the relevant generation before any replacement state is exposed.
- Observer exceptions do not exist in Swift closure signatures. Reentrant
  renderer errors are returned to the callback's caller and their queued error
  event follows normal operation ordering.

## Diagnostics

Internal test-visible diagnostics report:

- current pending event count;
- pending high-water;
- maximum observed callback depth;
- scheduled continuation count;
- coalesced runtime snapshot count;
- coalesced debug-frame event count; and
- stale-generation discard count; and
- retained consumed slot count, which must return to zero after every drain
  turn.

These values are diagnostics only and are not serialized into project data.

## Migration

1. Add and unit-test `RendererEventDispatcher` independently.
2. Replace the logical-dab staging arrays, scope depth, head index, and drain
   flags in `GridRenderer`.
3. Route runtime telemetry callbacks through the dispatcher.
4. Route error, idle, operation completion, and debug-frame callbacks through
   the same dispatcher.
5. Search for direct callback invocation in `GridRenderer`; the only remaining
   callback calls must be inside the dispatcher's single delivery adapter.

## Verification

Automated tests must prove:

- nested append/cancel/start never observes half-mutated state;
- a telemetry begin callback that cancels and starts a replacement stroke
  cannot be destroyed by the resumed outer begin;
- the same guarantee holds for telemetry end callbacks;
- self-feeding callbacks exceed 10,000 deliveries with callback depth one,
  bounded consumed storage, and more than one drain turn;
- nested inputs preserve exact FIFO dab order;
- stale queued events are skipped after cancel/reset/reconfiguration;
- partial batch failure publishes the accepted prefix exactly once and drops
  the failed suffix;
- runtime snapshot coalescing retains the newest value and records the drop;
- debug event coalescing behaves equivalently in debug builds;
- callback replacement and nil observers remain safe;
- existing canonical pixel, history, cancel, symmetry, renderer, runtime
  telemetry, and release-build suites remain green.

Task 5A is complete only after an independent reviewer finds no Critical or
Important issue and controller-owned verification passes.
