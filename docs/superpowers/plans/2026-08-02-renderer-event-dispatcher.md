# Renderer Event Dispatcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace every direct `GridRenderer` observer call with one transactional, generation-aware, non-recursive event dispatcher.

**Architecture:** A main-actor `RendererEventDispatcher` stages immutable events inside renderer operations and drains committed events through a compacting deque. Lossless semantic events preserve FIFO order; high-rate telemetry coalesces; each drain turn invokes at most 256 callbacks and schedules one main-actor continuation for remaining work.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, Metal, `@MainActor` concurrency.

## Global Constraints

- Direct work on `main` is explicitly authorized by the user.
- Preserve untracked `.vscode/` and `brushes/procreate/1_FREE_Charcoal_Set.key` unchanged.
- The design source of truth is `docs/superpowers/specs/2026-08-02-renderer-event-dispatcher-design.md`.
- Public callback property signatures and payload types must not change.
- `RendererEventDispatcher.deliveryBudgetPerTurn` is exactly `256` callback invocations.
- Lossless events are errors, idle changes, operation completions, logical dabs, and segment markers.
- Runtime snapshots and debug frame events coalesce to the newest undelivered value of their kind and generation.
- No public observer runs while renderer state is partially installed, mutated, rolled back, or torn down.
- Canonical pixels, stroke generation, history, cancel, tiling, and symmetry semantics must remain unchanged.
- Use test-driven development: add each regression test, run it red for the expected reason, then write production code.

---

### Task 1: Centralize Transactional Renderer Event Delivery

**Files:**

- Create: `Sources/MetalRenderer/StrokeRuntime/RendererEventDispatcher.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Create: `Tests/MetalRendererTests/RendererEventDispatcherTests.swift`
- Modify: `Tests/MetalRendererTests/DepositionRendererTests.swift`
- Modify: `Tests/MetalRendererTests/StrokeRuntimeTelemetryTests.swift`

**Interfaces:**

- Consumes: existing `GridRenderer` public callback payloads, stroke lifecycle APIs, `LogicalDab`, `StrokeRuntimeTelemetrySnapshot`, `StrokeRuntimeSegmentMarker`, `RendererOperationCompletion`, and `GPUFrameMetrics`.
- Produces: internal `RendererEvent`, `RendererEventDispatcher`, `RendererEventDispatcher.Diagnostics`, generation handles, transactional staging/checkpoints, and a single `GridRenderer.deliverRendererEvent(_:)` callback adapter.
- `RendererEventDispatcher` is a final `@MainActor` class and is not `Sendable`.
- `RendererEventDispatcher.deliveryBudgetPerTurn` equals `256`.
- `GridRenderer` must have no direct invocation of its public callback properties outside `deliverRendererEvent(_:)`.

- [ ] **Step 1: Write failing queue, transaction, and fair-drain tests**

Create `RendererEventDispatcherTests.swift` with real dispatcher tests that
name the production behavior. Use immutable integer probe payloads in an
internal test event case or the smallest real event payload available. Cover:

```swift
@Test @MainActor
func nestedEventsDrainFIFOWithoutRecursiveDelivery() async

@Test @MainActor
func failedNestedOperationDiscardsOnlyItsUncommittedSuffix() async

@Test @MainActor
func committedCheckpointSurvivesLaterOperationFailure() async

@Test @MainActor
func advancingGenerationSkipsQueuedStaleEvents() async

@Test @MainActor
func telemetryCoalescingKeepsNewestValueAndCountsReplacement() async

@Test @MainActor
func selfFeedingDrainYieldsEvery256CallbacksAndReclaimsConsumedStorage() async
```

The self-feeding test must deliver at least `10_000` callbacks, assert maximum
callback depth `== 1`, assert `scheduledContinuationCount > 1`, and assert
retained consumed slots never grow with the total delivered count. Tests may
use `await Task.yield()` only to allow the specified scheduled continuation to
run, never to mutate renderer state concurrently.

- [ ] **Step 2: Run the dispatcher tests and record RED evidence**

Run:

```bash
swift test --filter RendererEventDispatcherTests
```

Expected: fail because `RendererEventDispatcher` and its diagnostics do not
exist. Record the command, failing test/compiler diagnostic, and exit code in
the task report before adding production code.

- [ ] **Step 3: Implement the dispatcher with explicit transaction frames**

Create a focused implementation with this production shape:

```swift
@MainActor
final class RendererEventDispatcher {
    static let deliveryBudgetPerTurn = 256

    struct Diagnostics: Equatable {
        let pendingEventCount: Int
        let pendingHighWater: Int
        let maximumCallbackDepth: Int
        let scheduledContinuationCount: UInt64
        let coalescedRuntimeSnapshotCount: UInt64
        let coalescedDebugFrameEventCount: UInt64
        let staleGenerationDiscardCount: UInt64
        let retainedConsumedSlotCount: Int
    }

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

Use a deque/ring or compact after no more than 256 consumed callback
invocations. Remove an event from pending storage before delivery. Represent
logical-dab batches with a cursor so each observer invocation consumes one
unit of the 256 budget. Model nested operations with distinct staging frames;
do not reuse the old single depth plus global failure flag. After a budgeted
turn, schedule exactly one `Task { @MainActor [weak self] in ... }`
continuation when live events remain. The scheduled task may only deliver
already committed immutable events.

- [ ] **Step 4: Run the dispatcher tests and make them GREEN**

Run:

```bash
swift test --filter RendererEventDispatcherTests
```

Expected: all dispatcher tests pass with no unexpected warnings.

- [ ] **Step 5: Write failing `GridRenderer` reentrancy and ordering tests**

Add real-Metal tests, returning early only when Metal setup is unavailable:

```swift
@Test @MainActor
func runtimeBeginObserverCanCancelStartReplacementWithoutOuterBeginDestroyingIt() async throws

@Test @MainActor
func runtimeEndObserverCanStartReplacementWithoutOuterTeardownDestroyingIt() async throws

@Test @MainActor
func mixedLogicalDabAndRuntimeEventsPreserveCommittedOrder() async throws

@Test @MainActor
func partialBatchFailurePublishesAcceptedPrefixExactlyOnce() async throws

@Test @MainActor
func cancelInvalidatesQueuedOldStrokeEventsButKeepsReplacementEvents() async throws
```

The begin and end tests must invoke public renderer APIs synchronously from
the telemetry observer, retain the replacement token, and prove
`hasActiveStroke` remains true for that token after the original callback
chain returns. The partial-failure test must inject failure after at least one
accepted sample and compare published ordinals with coordinator commit
metadata.

- [ ] **Step 6: Run the renderer regressions and record RED evidence**

Run:

```bash
swift test --filter 'DepositionRendererTests|StrokeRuntimeTelemetryTests'
```

Expected: the new telemetry reentrancy tests fail against direct callback
delivery, while established tests remain green. Record the exact failing
assertions and exit code.

- [ ] **Step 7: Migrate every `GridRenderer` callback to the dispatcher**

Add one adapter:

```swift
private func deliverRendererEvent(_ event: RendererEvent) {
    switch event {
    case let .error(error):
        onError?(error)
    case let .idleStateChanged(isIdle):
        onIdleStateChange?(isIdle)
    case let .operationCompleted(completion):
        onOperationCompleted?(completion)
    case let .logicalDab(_, dab):
        onLogicalDabsGenerated?(dab)
    case let .strokeRuntimeSnapshot(_, snapshot):
        onStrokeRuntimeSnapshot?(snapshot)
    case let .strokeRuntimeSegmentMarker(_, marker):
        onStrokeRuntimeSegmentMarker?(marker)
    #if DEBUG
    case let .interactiveFramePresented(timestamp, count):
        onInteractiveFramePresented?(timestamp, count)
    case let .interactiveFrameMetrics(metrics):
        onInteractiveFrameMetrics?(metrics)
    #endif
    }
}
```

Replace the old logical-dab staging arrays, head index, depth/failure flags,
and drain helpers. Wrap each public mutation and main-actor completion handler
in dispatcher operation boundaries. Queue begin/end runtime marker and
snapshot payloads only after state installation/rollback/teardown completes.
Advance or invalidate stroke and telemetry generations at the lifecycle points
specified by the design. Keep accepted-prefix checkpoints in
`appendStrokeBatch`. Route error, idle, operation completion, and debug-frame
callbacks through the same adapter.

- [ ] **Step 8: Prove direct callback invocation is centralized**

Run:

```bash
rg -n 'on(Error|IdleStateChange|OperationCompleted|LogicalDabsGenerated|StrokeRuntimeSnapshot|StrokeRuntimeSegmentMarker|InteractiveFramePresented|InteractiveFrameMetrics)\?\(' Sources/MetalRenderer/GridRenderer.swift
```

Expected: matches occur only inside `deliverRendererEvent(_:)`.

- [ ] **Step 9: Run focused behavior and parity verification**

Run:

```bash
swift test --filter 'RendererEventDispatcherTests|DepositionRendererTests|StrokeRuntimeTelemetryTests|StrokeRenderCoordinatorTests|DepositionMetamorphicTests'
```

Expected: all selected tests pass. Confirm reentrancy tests executed rather
than returning early on the development Mac.

- [ ] **Step 10: Run broad renderer verification and a release build**

Run:

```bash
swift test --filter 'MetalRendererTests|PatternEngineTests.TransientStrokeBufferTests'
swift build -c release
git diff --check
```

Expected: all commands exit zero with no unexpected warnings or whitespace
errors.

- [ ] **Step 11: Self-review and commit**

Review the complete task diff against every design invariant, verify the two
original Task 5 review findings are structurally impossible, preserve the two
untracked user paths, then commit:

```bash
git add Sources/MetalRenderer/StrokeRuntime/RendererEventDispatcher.swift \
  Sources/MetalRenderer/GridRenderer.swift \
  Tests/MetalRendererTests/RendererEventDispatcherTests.swift \
  Tests/MetalRendererTests/DepositionRendererTests.swift \
  Tests/MetalRendererTests/StrokeRuntimeTelemetryTests.swift
git commit -m 'refactor(render): centralize callback delivery'
```
