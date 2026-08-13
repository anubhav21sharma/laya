# Interactive Brush Presentation Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the shipping Swift/Metal canvas responsive, bounded, and pixel-correct by decoupling brush-worker progress from drawable presentation, presenting persistent tile caches through the compiled symmetry fold, and proving the result in the actual Release app.

**Architecture:** Preserve the existing brush generator, sparse stroke surfaces, document transaction authority, history model, and export compositor. Add context-authenticated transient and canonical presentation caches, publish immutable revision-compatible presentation snapshots, and use a paused-view frame pump to render those caches directly; serialize the compiled periodic fold into the sparse sampling ABI instead of switching on tiling preset identifiers.

**Tech Stack:** Swift 6, Swift Testing/XCTest, Metal/MetalKit, Core Animation drawable presentation callbacks, XcodeGen, Bash 3.2-compatible acceptance scripts, JSONL evidence, macOS 14+, iPadOS 18+.

## Global Constraints

- Work on `main`; preserve unrelated untracked `.vscode/` and `brushes/procreate/1_FREE_Charcoal_Set.key` content.
- Do not replace the brush generator, dynamics engine, compiled symmetry model, sparse document store, history model, project format, or Metal deposition backend.
- Drawable availability, display preparation, and presentation completion must never grant brush-input or deposition-worker credit.
- Authoritative input must never be dropped, duplicated, reordered, or replaced by prediction; prediction must not change the settled canonical document hash.
- Every GPU-owned prepared stroke resource must settle exactly once through cache adoption, cancellation, or failure.
- Ordinary drawing work must be proportional to dirty canonical tiles and affected presentation regions, never full document area, and must allocate no three-texture full-drawable scratch set.
- One immutable presentation snapshot must supply geometry, tiling, layer, transient, viewport, backing-scale, and drawable revisions to a frame.
- CPU and GPU display folds must agree for every compiled periodic and finite symmetry family; do not add a shader preset-ID switch or a second tiling table.
- `LayerCompositor` remains available for stable capture/export only; ordinary `draw(in:)` must not enter it.
- Idle means all input, cache updates, submissions, leases, callbacks, and revisions are settled.
- Performance evidence must come from actual `CAMetalDrawable` presentation in the exact Release app; offscreen command completion cannot satisfy it.
- A true endurance run is 600 wall-clock seconds per required canvas size. Accelerated logical time is smoke evidence only.
- Timing runs use Metal validation disabled; correctness and ownership runs repeat with Metal validation enabled.
- Do not add source-text assertions, synthetic button-only checks, explicit offscreen completion drains, sleeps as synchronization, or logically scaled acceptance durations.
- Each red regression must fail on parent commit `796a5f6` for the intended behavior and fail again if its production condition is temporarily disabled after repair.

---

## File and Responsibility Map

### New production files

- `Sources/PatternEngine/CompiledPeriodicDisplayFold.swift`: normalized preset-independent periodic display-fold authority shared by CPU and Metal serialization.
- `Sources/MetalRenderer/StrokeRuntime/InteractiveBrushTrace.swift`: per-input shipping-path identities, stages, records, and sink contract.
- `Sources/MetalRenderer/Display/InteractiveFramePump.swift`: paused-`MTKView` redraw demand state machine.
- `Sources/MetalRenderer/Display/CanvasPresentationSnapshot.swift`: immutable compatible revision bundle for one display submission.
- `Sources/MetalRenderer/Display/CanvasDisplayOutputMapping.swift`: one strategy-to-output-mapping factory used by display and flattened export.
- `Sources/MetalRenderer/Display/InteractiveStrokePresentationCache.swift`: drawable-independent transient authoritative/prediction tile cache and prepared-page acknowledgement owner.
- `Sources/MetalRenderer/Display/CanvasCompositeTileCache.swift`: budgeted persistent canonical composite tile cache.
- `Sources/InteractiveBrushAcceptanceValidation/InteractiveBrushAcceptanceValidation.swift`: typed evidence decoding and fail-closed acceptance thresholds.
- `Sources/InteractiveBrushAcceptanceGate/main.swift`: command-line validator for one preserved run directory.
- `App/PatternSpike/Acceptance/InteractiveBrushTraceLogger.swift`: incremental JSONL writer and one-second heartbeat.
- `App/PatternSpike/Acceptance/InteractiveBrushAcceptanceConfiguration.swift`: environment-controlled shipping-app evidence configuration.
- `App/UITests/InteractiveBrushPresentationUITests.swift`: real pointer/window/zoom shipping-path behavioral tests.
- `scripts/run-interactive-brush-presentation-acceptance.sh`: Release build, smoke, validation, and true-endurance orchestrator.

### Existing authority files to modify

- `Sources/PatternEngine/CompiledSymmetry.swift`, `RectangularSymmetryKernel.swift`, `TriangularSymmetryKernel.swift`, and `SymmetryDescriptorCompiler.swift`: construct and consume one compiled periodic fold.
- `Sources/MetalRenderer/Raster/DocumentPaintSurfaceTransaction.swift`, `DocumentPaintSurfaceStore.swift`, and `DocumentPaintRenderContext.swift`: preserve dirty coordinates, capture one immutable geometry/layer epoch, and transfer exact cache ownership.
- `Sources/MetalRenderer/StrokeRuntime/StrokeInputQueue.swift`, `StrokeFrameScheduler.swift`, and `StrokeRuntimeTelemetry.swift`: retain per-input lineage and return worker credit after transient-cache completion.
- `Sources/MetalRenderer/Compositing/SparseTileSamplingPlan.swift`, `SparseTileSamplingPipeline.swift`, `LayerCompositor.swift`, `LayerBlendPipeline.swift`, `DocumentPaintStableSnapshotRenderer.swift`, `Sources/CShaderTypes/include/ShaderTypes.h`, `Sources/MetalRenderer/ShaderABI.swift`, and `Sources/MetalRenderer/Shaders.metal`: add the compiled-periodic mapping kind and ABI.
- `Sources/MetalRenderer/Display/CanvasDisplayCompositor.swift` and `Sources/MetalRenderer/GridRenderer.swift`: direct cache display, latest-wins retirement, frame pumping, presentation trace, atomic commit/cancel cutover, and shared flattened mapping.
- `App/PatternSpike/Canvas/InteractiveMetalView.swift`, `App/PatternSpike/Canvas/MetalCanvas.swift`, and `App/PatternSpike/ContentView.swift`: trace real input and enable acceptance logging without changing shipping input behavior.
- `Package.swift` and `App/project.yml`: validation targets plus Release macOS and iPadOS shipping-route acceptance schemes.

---

### Task 1: Shipping-Path Trace Identity and Incremental Evidence

**Files:**
- Create: `Sources/MetalRenderer/StrokeRuntime/InteractiveBrushTrace.swift`
- Create: `App/PatternSpike/Acceptance/InteractiveBrushTraceLogger.swift`
- Create: `App/PatternSpike/Acceptance/InteractiveBrushAcceptanceConfiguration.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokeRuntimeTelemetry.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokeInputQueue.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokeFrameScheduler.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `App/PatternSpike/Canvas/InteractiveMetalView.swift`
- Modify: `App/PatternSpike/ContentView.swift`
- Modify: `Package.swift`
- Test: `Tests/MetalRendererTests/StrokeRuntimeTelemetryTests.swift`
- Test: `App/Tests/InteractiveBrushTraceLoggerTests.swift`

**Interfaces:**
- Consumes: existing `StrokeSample`, `StrokePreparedDepositionBatch`, `GPUFrameMetrics`, and renderer-event plumbing.
- Produces:

```swift
public struct StrokeTraceIdentity: Hashable, Codable, Sendable {
    public let strokeGeneration: UInt64
    public let authoritativeSequence: UInt64
    public let sampleSequence: UInt64
    public let provenance: StrokeTraceProvenance
}

public enum StrokeTraceProvenance: String, Codable, Sendable {
    case authoritative
    case coalesced
    case predicted
}

public enum InteractiveBrushTraceStage: String, Codable, Sendable {
    case eventReceived
    case workerDequeued
    case dabPrepared
    case transientCacheSubmitted
    case transientCacheCompleted
    case drawableSubmitted
    case drawablePresented
    case settled
    case progress
    case failure
}

public struct InteractiveBrushTraceRecord: Codable, Sendable {
    public let schemaVersion: UInt32
    public let stage: InteractiveBrushTraceStage
    public let identity: StrokeTraceIdentity?
    public let monotonicNanoseconds: UInt64
    public let documentGeneration: UInt64?
    public let canonicalRevision: UInt64?
    public let transientRevision: UInt64?
    public let presentationRevision: UInt64?
    public let authoritativeBacklog: Int
    public let dirtyTileCount: Int
    public let residentBytes: Int
    public let activeOwnershipCount: Int
    public let message: String?
}

public protocol InteractiveBrushTraceSink: Sendable {
    func record(_ record: InteractiveBrushTraceRecord)
}
```

The optional trace identity and original event-receipt uptime travel with each `StrokeSample`, scheduler input, prepared batch, cache update, and frame lineage. Predicted identities remain distinguishable and never satisfy authoritative acceptance.

- [ ] **Step 1: Write red lineage and logger tests**

Add a behavioral trace test that feeds authoritative, coalesced, and predicted samples through the real queue/scheduler seam and asserts identity preservation and monotonic stages:

```swift
@Test
func shippingTracePreservesPerInputIdentityAndMonotonicStageOrder() async throws {
    let rig = try await StrokeRuntimeTelemetryTestRig.makeTracing()
    let inputs = try await rig.submitMixedPointerPacket()
    try await rig.finishAndSettle()

    for input in inputs where input.provenance != .predicted {
        let stages = rig.records(for: input.identity).map(\.stage)
        #expect(stages.starts(with: [
            .eventReceived, .workerDequeued, .dabPrepared,
        ]))
        #expect(stages.last == .settled)
        #expect(rig.records(for: input.identity).map(\.monotonicNanoseconds)
            == rig.records(for: input.identity).map(\.monotonicNanoseconds).sorted())
    }
    #expect(Set(inputs.map(\.identity)).count == inputs.count)
}
```

Add logger tests that open the JSONL while the logger is still active, advance an injected `ContinuousClock`, and assert one heartbeat per elapsed wall second and a terminal `.failure` if the bounded writer queue rejects a record.

- [ ] **Step 2: Run the trace tests and verify the intended failures**

Run:

```bash
swift test --filter StrokeRuntimeTelemetryTests.shippingTracePreservesPerInputIdentityAndMonotonicStageOrder
swift test --filter InteractiveBrushTraceLoggerTests
```

Expected: the first test fails because no per-input production lineage exists; the logger tests fail because no shipping JSONL/heartbeat component exists.

- [ ] **Step 3: Implement identity propagation and the environment-disabled sink**

Assign `authoritativeSequence` at real event receipt in `InteractiveMetalView`, preserve it through coalescing, and assign separate predicted provenance. Record queue/scheduler stages without aggregating identities. Implement `InteractiveBrushAcceptanceConfiguration` so logging is inactive unless `INTERACTIVE_BRUSH_ACCEPTANCE_LOG` is an absolute file path. Implement the logger with a bounded serial writer, newline-delimited `JSONEncoder` output, `FileHandle.synchronize()` after each record in acceptance mode, and an injected clock for deterministic tests. A queue overflow records a terminal failure and makes `finish()` throw.

Add both new app production files and `Tests/InteractiveBrushTraceLoggerTests.swift` to the existing `EditorSessionControllerTests` target's explicit `Package.swift` source list. Do not add drawable stages here; Task 4 publishes cache stages and Task 9 adds actual `CAMetalDrawable` submission/presentation.

- [ ] **Step 4: Re-run focused tests**

Run the two commands from Step 2 plus:

```bash
swift test --filter 'StrokeFrameSchedulerTests|StrokeRuntimeTelemetryTests'
```

Expected: all selected tests pass; JSONL is readable before logger shutdown; heartbeat timestamps are based on wall time.

- [ ] **Step 5: Commit the trace foundation**

```bash
git add Package.swift Sources/MetalRenderer/StrokeRuntime/InteractiveBrushTrace.swift Sources/MetalRenderer/StrokeRuntime/StrokeRuntimeTelemetry.swift Sources/MetalRenderer/StrokeRuntime/StrokeInputQueue.swift Sources/MetalRenderer/StrokeRuntime/StrokeFrameScheduler.swift Sources/MetalRenderer/GridRenderer.swift App/PatternSpike/Acceptance App/PatternSpike/Canvas/InteractiveMetalView.swift App/PatternSpike/ContentView.swift Tests/MetalRendererTests/StrokeRuntimeTelemetryTests.swift App/Tests/InteractiveBrushTraceLoggerTests.swift
git commit -m "feat: trace shipping brush input"
```

---

### Task 2: Exact Canonical Identity and Dirty-Tile Publication

**Files:**
- Modify: `Sources/MetalRenderer/Raster/DocumentPaintSurfaceTransaction.swift`
- Modify: `Sources/MetalRenderer/Raster/DocumentPaintSurfaceStore.swift`
- Modify: `Sources/MetalRenderer/Raster/DocumentPaintRenderContext.swift`
- Test: `Tests/MetalRendererTests/DocumentPaintSurfaceTransactionTests.swift`
- Test: `Tests/MetalRendererTests/DocumentPaintRenderContextTests.swift`
- Test: `Tests/MetalRendererTests/RendererResizeTests.swift`

**Interfaces:**
- Consumes: existing `DocumentPaintSurfaceCommitResult.dirtyCoordinates`, `DocumentPaintGeometry`, document generation, and layer-stack mutation paths.
- Produces:

```swift
struct CanvasCanonicalStateIdentity: Equatable, Sendable {
    let documentGeneration: UInt64
    let geometry: DocumentPaintGeometry
    let geometryRevision: UInt64
    let layerStackRevision: UInt64
    let compositeRevision: UInt64
}

struct DocumentPaintSurfaceApplicationResult: Equatable, Sendable {
    let didPublish: Bool
    let layerID: UUID
    let generation: UInt64
    let dirtyCoordinates: [PaintTileCoordinate]
    let canonicalIdentity: CanvasCanonicalStateIdentity
    let historyPair: PendingRasterRevisionPair?
}
```

Revision counters use checked increment and fail closed on overflow. Geometry/document replacement advances geometry, layer-stack, and composite revisions; layer order/blend/opacity/visibility advances layer-stack and composite revisions; tile content mutation advances composite revision and returns exact sorted dirties.

- [ ] **Step 1: Write red transaction identity tests**

Add tests that commit two far-apart dirty tiles and assert the application result preserves exactly those coordinates, while an opacity change advances the layer/composite revisions without inventing tile dirties:

```swift
@Test
func applicationResultPreservesExactCommitDirtiesAndCanonicalIdentity() async throws {
    let rig = try await DocumentPaintTransactionTestRig.make()
    let coordinates = [PaintTileCoordinate(x: 0, y: 0),
                       PaintTileCoordinate(x: 31, y: 17)]
    let before = await rig.context.canonicalStateIdentity()
    let result = try await rig.commitOpaqueTiles(at: coordinates)

    #expect(result.dirtyCoordinates == coordinates.sorted())
    #expect(result.canonicalIdentity.documentGeneration == before.documentGeneration)
    #expect(result.canonicalIdentity.compositeRevision == before.compositeRevision + 1)
    #expect(result.canonicalIdentity.layerStackRevision == before.layerStackRevision)
}
```

Extend resize/history tests to assert restored dimensions and bytes carry a new compatible geometry identity rather than reusing the superseded one.

- [ ] **Step 2: Run the tests and verify dirty coordinates are currently lost**

```bash
swift test --filter 'DocumentPaintSurfaceTransactionTests|DocumentPaintRenderContextTests|RendererResizeTests'
```

Expected: new assertions fail because `DocumentPaintSurfaceApplicationResult` currently drops `dirtyCoordinates` and has no canonical identity.

- [ ] **Step 3: Implement context-owned checked revisions**

Forward `DocumentPaintSurfaceCommitResult.dirtyCoordinates` from `DocumentPaintTransactionWorker.executeMutation`. Centralize identity advancement in `DocumentPaintRenderContext`; do not derive these counters in `GridRenderer`. Sort and deduplicate dirties at the transaction boundary and reject coordinates outside the captured geometry.

- [ ] **Step 4: Re-run the focused transaction/resize suites**

```bash
swift test --filter 'DocumentPaintSurfaceTransactionTests|DocumentPaintRenderContextTests|RendererResizeTests'
```

Expected: all selected tests pass, including exact history restore identities.

- [ ] **Step 5: Commit canonical revision publication**

```bash
git add Sources/MetalRenderer/Raster/DocumentPaintSurfaceTransaction.swift Sources/MetalRenderer/Raster/DocumentPaintSurfaceStore.swift Sources/MetalRenderer/Raster/DocumentPaintRenderContext.swift Tests/MetalRendererTests/DocumentPaintSurfaceTransactionTests.swift Tests/MetalRendererTests/DocumentPaintRenderContextTests.swift Tests/MetalRendererTests/RendererResizeTests.swift
git commit -m "feat: publish exact canvas revisions"
```

---

### Task 3: Interactive Frame Pump and Immutable Snapshot Retirement

**Files:**
- Create: `Sources/MetalRenderer/Display/InteractiveFramePump.swift`
- Create: `Sources/MetalRenderer/Display/CanvasPresentationSnapshot.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/Display/CanvasDisplayCompositor.swift`
- Test: `Tests/MetalRendererTests/InteractiveFrameTimestampTests.swift`
- Test: `Tests/MetalRendererTests/GridRendererSparseCutoverTests.swift`
- Test: `Tests/MetalRendererTests/RendererResizeTests.swift`

**Interfaces:**
- Consumes: `CanvasCanonicalStateIdentity` from Task 2, renderer viewport/drawable/backing-scale state, active transient generation, and `MTKView.setNeedsDisplay`.
- Produces:

```swift
struct CanvasPresentationRevision: Equatable, Comparable, Sendable {
    let sequence: UInt64
}

struct CanvasPresentationSnapshot: @unchecked Sendable {
    let revision: CanvasPresentationRevision
    let canonicalIdentity: CanvasCanonicalStateIdentity
    let canonicalCacheRevision: UInt64
    let transientGeneration: UInt64?
    let transientRevision: UInt64?
    let outputMappingRevision: UInt64
    let viewportRevision: UInt64
    let viewport: ViewportTransform
    let drawablePixelSize: PixelSize
    let backingScaleRevision: UInt64
    let showGridLines: Bool
    let showCanvasBoundary: Bool

    func validateCompatibility() throws
}

struct InteractiveFramePump: Sendable {
    mutating func signal(_ demand: InteractiveFrameDemand)
    mutating func beginFrame() -> CanvasPresentationRevision?
    mutating func finishFrame(_ outcome: InteractiveFrameOutcome) -> Bool
    mutating func markPresented(_ revision: CanvasPresentationRevision) -> Bool
    var hasDemand: Bool { get }
}

enum InteractiveFrameDemand: Equatable, Sendable {
    case input
    case cachePublished(CanvasPresentationRevision)
    case viewportChanged(CanvasPresentationRevision)
    case drawableChanged(CanvasPresentationRevision)
    case telemetry
}

enum InteractiveFrameOutcome: Equatable, Sendable {
    case submitted(CanvasPresentationRevision)
    case superseded(CanvasPresentationRevision)
    case drawableUnavailable(CanvasPresentationRevision?)
    case noCompatibleSnapshot(CanvasPresentationRevision?)
    case failed(CanvasPresentationRevision?, String)
}
```

Only the latest compatible prepared snapshot may publish. An older preparation is retained as `retiring` until its task and any GPU submission settle; cancellation is a request, not proof of retirement. There is at most one exclusive preparation in flight.

- [ ] **Step 1: Write red pump and gated-retirement tests**

Add pure pump tests for active demand, missing drawable, newest presentation, and idle settlement. Add an injected `PresentationPreparationGate` in renderer tests: pause revision 1, invalidate to revisions 2 and 3, release revision 1, and assert `maximumConcurrentPreparationCount == 1`, revision 3 alone publishes, and all retirement ownership reaches zero.

```swift
@Test
func activeUnpresentedRevisionRequestsAnotherPausedViewFrame() {
    var pump = InteractiveFramePump()
    let revision = CanvasPresentationRevision(sequence: 7)
    pump.signal(.cachePublished(revision))
    #expect(pump.beginFrame() == revision)
    #expect(pump.finishFrame(.submitted(revision)))
    #expect(pump.hasDemand)
    #expect(!pump.markPresented(revision))
    #expect(!pump.hasDemand)
}
```

- [ ] **Step 2: Run and confirm starvation/retirement failures**

```bash
swift test --filter 'InteractiveFrameTimestampTests|GridRendererSparseCutoverTests|RendererResizeTests'
```

Expected: pump types are absent; the gated test exposes cancel/nil/immediate-reschedule behavior or no continuation frame request.

- [ ] **Step 3: Install pump transitions on every draw exit**

Replace the dead `requestAnotherInteractiveFrameIfNeeded` helper with the pump. `draw(in:)` calls `beginFrame()` once and routes every guard/return through one `finishFrame` helper. If `finishFrame` returns `true`, call `view.setNeedsDisplay(view.bounds)` on the main actor. Signal the pump on input admission, cache/display preparation publication, drawable-size change, viewport change, command completion, and later drawable presentation.

Refactor preparation into explicit `active`, `retiring`, and `pendingLatestSnapshot` state. Snapshot validation must happen before encoding and include both conflicting revision values in an internal diagnostic. Superseded work must not reach the user error banner.

- [ ] **Step 4: Re-run pump, sparse cutover, and resize suites**

```bash
swift test --filter 'InteractiveFrameTimestampTests|GridRendererSparseCutoverTests|RendererResizeTests'
```

Expected: all pass; gated maximum concurrency is one; a missing drawable retains demand; presenting the newest revision settles the pump.

- [ ] **Step 5: Commit scheduling/revision repair**

```bash
git add Sources/MetalRenderer/Display/InteractiveFramePump.swift Sources/MetalRenderer/Display/CanvasPresentationSnapshot.swift Sources/MetalRenderer/GridRenderer.swift Sources/MetalRenderer/Display/CanvasDisplayCompositor.swift Tests/MetalRendererTests/InteractiveFrameTimestampTests.swift Tests/MetalRendererTests/GridRendererSparseCutoverTests.swift Tests/MetalRendererTests/RendererResizeTests.swift
git commit -m "fix: serialize canvas presentation"
```

---

### Task 4: Drawable-Independent Transient Stroke Cache

**Files:**
- Create: `Sources/MetalRenderer/Display/InteractiveStrokePresentationCache.swift`
- Modify: `Sources/MetalRenderer/Raster/DocumentPaintRenderContext.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokeInputQueue.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokeFrameScheduler.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Test: `Tests/MetalRendererTests/InteractiveStrokePresentationCacheTests.swift`
- Test: `Tests/MetalRendererTests/StrokeFrameSchedulerTests.swift`
- Test: `Tests/MetalRendererTests/StrokeTileSurfaceEncoderTests.swift`
- Test: `Tests/MetalRendererTests/DocumentPaintRenderContextTests.swift`
- Test: `Tests/MetalRendererTests/GridRendererSparseCutoverTests.swift`

**Interfaces:**
- Consumes: authenticated `StrokePreparedDisplayFrame`, exact `StrokePreparedFrameAcknowledgement`, existing authoritative/prediction tile references, trace stages from Task 1, and canonical geometry identity from Task 2.
- Produces:

```swift
struct DocumentPaintTransientCacheUpdate: @unchecked Sendable {
    let generation: UInt64
    let sequence: UInt64
    let layerID: UUID
    let canonicalIdentity: CanvasCanonicalStateIdentity
    let changedRole: StrokePrivateSurfaceLayer
    let changedCoordinates: [PaintTileCoordinate]
    let clearedAuthoritativeSurface: Bool
    let clearedPredictionSurface: Bool
    let descriptor: DocumentPaintTransientVisibleSourceDescriptor
    let acknowledgement: StrokePreparedFrameAcknowledgement
    let traceIdentities: [StrokeTraceIdentity]
}

struct InteractiveStrokeCompositeParameters: Equatable, Sendable {
    let blendMode: LayerBlendMode
    let opacity: Float
}

struct InteractiveStrokePresentationRevision: Equatable, Comparable, Sendable {
    let generation: UInt64
    let sequence: UInt64
}

struct InteractiveStrokePresentationSnapshot: @unchecked Sendable {
    let revision: InteractiveStrokePresentationRevision
    let canonicalIdentity: CanvasCanonicalStateIdentity
    let authoritative: TiledRasterExactReferenceProvider?
    let prediction: TiledRasterExactReferenceProvider?
    let parameters: InteractiveStrokeCompositeParameters
}

actor InteractiveStrokePresentationCache {
    func adopt(
        _ update: DocumentPaintTransientCacheUpdate,
        parameters: InteractiveStrokeCompositeParameters
    ) async throws -> InteractiveStrokePresentationRevision
    func current(generation: UInt64) throws
        -> InteractiveStrokePresentationSnapshot?
    func retire(generation: UInt64) async throws
    func cancel(generation: UInt64) async throws
    func snapshot() -> InteractiveStrokePresentationCacheSnapshot
}
```

`DocumentPaintRenderContext.makeTransientCacheUpdate(frame:sequence:)` derives addressing from its captured registry geometry, authenticates the capability, and transfers the exact acknowledgement. It must not retain `StrokePreparedDepositionBatch` array views. The cache owns two `TiledRasterSurface` namespaces, copies only changed tiles, keeps the previous completed revision during the next update, and allows at most two update slots.

- [ ] **Step 1: Write red acknowledgement and bounded-cache tests**

Create tests with gated Metal completion and a nil drawable:

```swift
@Test
func drawableUnavailabilityDoesNotBlockPreparedPageAcknowledgement() async throws {
    let rig = try await InteractiveStrokePresentationCacheTestRig.make(
        drawableAvailable: false,
        gateGPUCompletion: true
    )
    let update = try await rig.makePreparedUpdate(dirtyTiles: [.zero])
    let adoption = Task { try await rig.cache.adopt(update, parameters: rig.parameters) }

    await rig.waitForCacheSubmission()
    #expect(!update.acknowledgement.isFulfilled)
    rig.releaseGPUCompletion()
    _ = try await adoption.value

    #expect(update.acknowledgement.isFulfilled)
    #expect(await rig.workerCanTakeNextAuthoritativeInput())
    #expect(rig.drawableSubmissionCount == 0)
}
```

Also cover success/failure/cancellation exactly-once settlement, previous-revision visibility, exact changed coordinates, prediction clear/replace, two-slot maximum, and resident/high-water byte accounting.

- [ ] **Step 2: Run and confirm current display-coupled credit failure**

```bash
swift test --filter 'InteractiveStrokePresentationCacheTests|StrokeFrameSchedulerTests|StrokeTileSurfaceEncoderTests|DocumentPaintRenderContextTests|GridRendererSparseCutoverTests'
```

Expected: new types are absent and the reversed sparse-cutover expectation fails because worker progress currently waits for display submission acknowledgement.

- [ ] **Step 3: Implement cache adoption and move exact ACK ownership**

Copy only the authenticated changed role/coordinates into cache-owned tile surfaces. Publish the revision only after command completion, then request and complete the exact acknowledgement. On encoding failure or cancellation, settle the acknowledgement/capability exactly once and preserve the last complete revision only when its ownership remains valid. Remove prepared-page acknowledgement from `PreparedLayerCompositeDisplaySubmission` terminal handling. Emit `.transientCacheSubmitted` and `.transientCacheCompleted` for every carried trace identity.

- [ ] **Step 4: Re-run ownership and queue suites**

```bash
swift test --filter 'InteractiveStrokePresentationCacheTests|StrokeFrameSchedulerTests|StrokeTileSurfaceEncoderTests|DocumentPaintRenderContextTests|GridRendererSparseCutoverTests'
```

Expected: all pass; mailbox capacity may remain one because credit now returns after bounded cache completion rather than presentation; every acknowledgement count is exactly one.

- [ ] **Step 5: Commit transient cache ownership**

```bash
git add Sources/MetalRenderer/Display/InteractiveStrokePresentationCache.swift Sources/MetalRenderer/Raster/DocumentPaintRenderContext.swift Sources/MetalRenderer/StrokeRuntime/StrokeInputQueue.swift Sources/MetalRenderer/StrokeRuntime/StrokeFrameScheduler.swift Sources/MetalRenderer/GridRenderer.swift Tests/MetalRendererTests/InteractiveStrokePresentationCacheTests.swift Tests/MetalRendererTests/StrokeFrameSchedulerTests.swift Tests/MetalRendererTests/StrokeTileSurfaceEncoderTests.swift Tests/MetalRendererTests/DocumentPaintRenderContextTests.swift Tests/MetalRendererTests/GridRendererSparseCutoverTests.swift
git commit -m "feat: decouple stroke cache credit"
```

---

### Task 5: Persistent Canonical Composite Tile Cache

**Files:**
- Create: `Sources/MetalRenderer/Display/CanvasCompositeTileCache.swift`
- Modify: `Sources/MetalRenderer/Raster/DocumentPaintSurfaceStore.swift`
- Modify: `Sources/MetalRenderer/Raster/DocumentPaintRenderContext.swift`
- Modify: `Sources/MetalRenderer/Compositing/LayerCompositor.swift`
- Test: `Tests/MetalRendererTests/CanvasCompositeTileCacheTests.swift`
- Test: `Tests/MetalRendererTests/DocumentPaintSurfaceStoreTests.swift`
- Test: `Tests/MetalRendererTests/LayerCompositorTests.swift`

**Interfaces:**
- Consumes: `CanvasCanonicalStateIdentity`, exact commit dirties, existing layer ordering/blend/opacity semantics, `PaintTileStore`, and tile-local sparse plans.
- Produces:

```swift
struct CanvasCompositeTileKey: Hashable, Sendable {
    let coordinate: PaintTileCoordinate
    let documentGeneration: UInt64
    let geometryRevision: UInt64
    let layerStackRevision: UInt64
    let compositeRevision: UInt64
}

final class CanvasCompositeTileUpdatePlan: @unchecked Sendable {
    let identity: CanvasCanonicalStateIdentity
    let dirtyCoordinates: [PaintTileCoordinate]
    let preparedTiles: [PreparedLayerCompositeTile]
    func close()
}

struct CanvasCompositeRevision: Equatable, Comparable, Sendable {
    let identity: CanvasCanonicalStateIdentity
    let sequence: UInt64
}

struct CanvasCompositeTileSnapshot: @unchecked Sendable {
    let revision: CanvasCompositeRevision
    let provider: TiledRasterExactReferenceProvider
    let residentByteCount: Int
}

actor CanvasCompositeTileCache {
    func apply(_ plan: CanvasCompositeTileUpdatePlan) async throws
        -> CanvasCompositeRevision
    func invalidateAll(identity: CanvasCanonicalStateIdentity) async throws
        -> CanvasCompositeRevision
    func current(expected: CanvasCompositeRevision) throws
        -> CanvasCompositeTileSnapshot
    func snapshot() -> CanvasCompositeTileCacheSnapshot
}
```

`DocumentPaintSurfaceStore.prepareCompositeTileUpdatePlan(dirtyCoordinates:expectedIdentity:limits:)` installs one aggregate exact capture for one frozen registry epoch/layer stack and returns tile-local plans. Disjoint dirty tiles must not become one bounding rectangle. Cache composition uses tile-sized targets and at most tile-sized scratch.

- [ ] **Step 1: Write red exact-dirty, blend-parity, and budget tests**

Add tests that mutate two far-apart tiles, compare each resulting tile against the existing layer-compositor oracle, and assert unaffected physical references remain identical:

```swift
@Test
func mutationRecompositesOnlyDirtyCanonicalTiles() async throws {
    let rig = try await CanvasCompositeTileCacheTestRig.make(
        residentBudgetBytes: 8 * 1024 * 1024
    )
    let initial = try await rig.populateFourTiles()
    let dirties = [PaintTileCoordinate(x: 0, y: 0),
                   PaintTileCoordinate(x: 29, y: 17)]
    let revision = try await rig.mutateAndApply(dirties)
    let current = try await rig.cache.current(expected: revision)

    #expect(current.changedCoordinates(from: initial) == dirties.sorted())
    #expect(current.unchangedReferences(from: initial).count == 2)
    #expect(try await rig.bytesMatchLayerCompositorOracle(at: dirties))
    #expect(await rig.maximumScratchPixelCount <= PaintTileDescriptor.pixelCount)
}
```

Cover normal/multiply/screen blend, opacity, erase, transparent removal, stale identity before encoding, deterministic eviction, closed budget failure with requested/current/high-water bytes, and full invalidation only for layer-wide/document changes.

- [ ] **Step 2: Run and confirm no persistent canonical cache exists**

```bash
swift test --filter 'CanvasCompositeTileCacheTests|DocumentPaintSurfaceStoreTests|LayerCompositorTests'
```

Expected: new tests fail because ordinary composite output is full-drawable and ephemeral.

- [ ] **Step 3: Implement epoch-consistent tile-local composition**

Freeze geometry/layer identity once, install one aggregate exact capture, prepare individual tile plans, and close all leases on every terminal path. Back the cache with a budgeted `PaintTileStore`/`TiledRasterSurface`, use deterministic least-recently-presented eviction only for reconstructible tiles, and expose current/high-water/reserved bytes plus active capture/update counts. Keep the existing full-output compositor untouched for capture/export.

- [ ] **Step 4: Re-run cache/store/compositor tests**

```bash
swift test --filter 'CanvasCompositeTileCacheTests|DocumentPaintSurfaceStoreTests|LayerCompositorTests'
```

Expected: all pass; disjoint dirties allocate two tile targets, not their bounding rectangle.

- [ ] **Step 5: Commit persistent canonical caching**

```bash
git add Sources/MetalRenderer/Display/CanvasCompositeTileCache.swift Sources/MetalRenderer/Raster/DocumentPaintSurfaceStore.swift Sources/MetalRenderer/Raster/DocumentPaintRenderContext.swift Sources/MetalRenderer/Compositing/LayerCompositor.swift Tests/MetalRendererTests/CanvasCompositeTileCacheTests.swift Tests/MetalRendererTests/DocumentPaintSurfaceStoreTests.swift Tests/MetalRendererTests/LayerCompositorTests.swift
git commit -m "feat: cache canonical composite tiles"
```

---

### Task 6: Atomic Stroke Cutover and Direct Cache Display

**Files:**
- Modify: `Sources/MetalRenderer/Display/CanvasPresentationSnapshot.swift`
- Modify: `Sources/MetalRenderer/Display/CanvasDisplayCompositor.swift`
- Modify: `Sources/MetalRenderer/Raster/DocumentPaintRenderContext.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/Shaders.metal`
- Test: `Tests/MetalRendererTests/CanvasPresentationCacheTests.swift`
- Test: `Tests/MetalRendererTests/GridRendererSparseCutoverTests.swift`
- Test: `Tests/MetalRendererTests/LayerCompositorTests.swift`
- Test: `Tests/MetalRendererTests/StageDAcceptanceTests.swift`

**Interfaces:**
- Consumes: canonical/transient snapshots from Tasks 4-5 and pump/snapshot revision machinery from Task 3.
- Produces:

```swift
struct CanvasPresentationSnapshot: @unchecked Sendable {
    let revision: CanvasPresentationRevision
    let canonicalIdentity: CanvasCanonicalStateIdentity
    let canonical: CanvasCompositeTileSnapshot
    let transient: InteractiveStrokePresentationSnapshot?
    let outputMapping: SparseTileSamplingOutputMapping
    let viewport: ViewportTransform
    let drawablePixelSize: PixelSize
    let backingScaleRevision: UInt64
    let showGridLines: Bool
    let showCanvasBoundary: Bool
}

final class CanvasDisplaySubmission: @unchecked Sendable {
    let revision: CanvasPresentationRevision
    let commandBuffer: MTLCommandBuffer
    func markTerminal(_ disposition: CanvasDisplayTerminalDisposition)
}

enum CanvasDisplayCompositor {
    static func prepare(
        snapshot: CanvasPresentationSnapshot,
        pipelines: DocumentPaintVisiblePlanPipelines
    ) async throws -> CanvasDisplaySubmission
}
```

Display submissions own sampling leases only and never own a scheduler acknowledgement. The fragment path samples canonical plus optional transient authoritative/prediction content and applies existing normal/erase/prediction semantics directly into the drawable.

- [ ] **Step 1: Write red cutover, no-scratch, and large-drawable tests**

Add gated commit tests asserting frames remain `old canonical + completed transient` until the canonical dirty update publishes, then atomically become `new canonical + no matching transient`; no intermediate hash may be blank or double-painted. Add cancellation assertions that canonical hash/revision do not change.

Add direct-display tests:

```swift
@Test
func maximized3024By1964DrawablePresentsFromTileCaches() async throws {
    let rig = try await CanvasPresentationCacheTestRig.make(
        drawableSize: PixelSize(width: 3024, height: 1964)
    )
    try await rig.drawCommittedAndTransientContent()
    let evidence = try await rig.presentNewestSnapshot()

    #expect(evidence.didPresent)
    #expect(evidence.interactiveLayerCompositorEntryCount == 0)
    #expect(evidence.fullDrawableScratchBytes == 0)
    #expect(evidence.error == nil)
}
```

Extend settled-idle tests to require zero cache updates, submissions, leases, callbacks, acknowledgements, retiring preparations, and transient generations.

- [ ] **Step 2: Run and confirm current full-drawable/cutover failures**

```bash
swift test --filter 'CanvasPresentationCacheTests|GridRendererSparseCutoverTests|LayerCompositorTests|StageDAcceptanceTests'
```

Expected: current ordinary display enters `LayerCompositor`, the reported drawable exceeds scratch, and commit abandons transient display before canonical cache publication.

- [ ] **Step 3: Implement atomic publication and direct sparse sampling**

Change commit order to: complete final transient cache update and ACK; publish document transaction; apply exact canonical dirties; atomically publish canonical-without-transient snapshot; retire transient generation. Change cancellation to settle/cancel any update, retire transient generation, then cancel the capability without touching canonical cache.

Build one direct display pass over canonical and optional transient providers. Remove `prepareLayerDisplaySubmission` from normal `GridRenderer.draw(in:)`; retain it only in stable capture/export paths. Attach sampling lease settlement to command terminal state. Extend idle snapshots with every new ownership counter.

- [ ] **Step 4: Re-run cache-display and settlement suites**

```bash
swift test --filter 'CanvasPresentationCacheTests|GridRendererSparseCutoverTests|LayerCompositorTests|StageDAcceptanceTests|StrokeTileSurfaceEncoderTests'
```

Expected: all pass; a >4,194,304-pixel drawable uses zero interactive full-output scratch; cutover has no blank/double frame; idle ownership is zero.

- [ ] **Step 5: Commit direct cache presentation**

```bash
git add Sources/MetalRenderer/Display/CanvasPresentationSnapshot.swift Sources/MetalRenderer/Display/CanvasDisplayCompositor.swift Sources/MetalRenderer/Raster/DocumentPaintRenderContext.swift Sources/MetalRenderer/GridRenderer.swift Sources/MetalRenderer/Shaders.metal Tests/MetalRendererTests/CanvasPresentationCacheTests.swift Tests/MetalRendererTests/GridRendererSparseCutoverTests.swift Tests/MetalRendererTests/LayerCompositorTests.swift Tests/MetalRendererTests/StageDAcceptanceTests.swift
git commit -m "feat: present canvas tile caches"
```

---

### Task 7: One Compiled Periodic Display-Fold Authority

**Files:**
- Create: `Sources/PatternEngine/CompiledPeriodicDisplayFold.swift`
- Modify: `Sources/PatternEngine/CompiledSymmetry.swift`
- Modify: `Sources/PatternEngine/SymmetryDescriptorCompiler.swift`
- Modify: `Sources/PatternEngine/RectangularSymmetryKernel.swift`
- Modify: `Sources/PatternEngine/TriangularSymmetryKernel.swift`
- Modify: `Sources/PatternEngine/TilingStrategy.swift`
- Test: `Tests/PatternEngineTests/RectangularSymmetryKernelParityTests.swift`
- Test: `Tests/PatternEngineTests/TriangularSymmetryKernelTests.swift`
- Test: `Tests/PatternEngineTests/TilingStrategyTests.swift`

**Interfaces:**
- Consumes: normalized `CompiledPeriodicDomain.worldToLattice`, tile/repeat sizes, phase program, alternating reflections, and symmetry family.
- Produces:

```swift
public enum CompiledPeriodicFoldCoordinateSpace: UInt32, Sendable {
    case axisAlignedRepeat = 0
    case unitLattice = 1
}

public struct CompiledPeriodicDisplayFold: Equatable, Sendable {
    public let family: SymmetryKernelFamily
    public let coordinateSpace: CompiledPeriodicFoldCoordinateSpace
    public let worldToLattice: Affine2D
    public let canonicalSize: PatternSize
    public let repeatSize: PatternSize
    public let phase: PeriodicPhaseProgram?
    public let alternatingReflections: SymmetryReflectionAxes

    public func applying(to world: WorldPoint) -> CanonicalPoint
}

public struct CompiledPeriodicDomain: Equatable, Sendable {
    // Existing fields remain.
    public let displayFold: CompiledPeriodicDisplayFold
}
```

Choose `.unitLattice` structurally for triangular families or a non-axis-aligned rectangular basis; otherwise choose `.axisAlignedRepeat`. Phase capacity remains the compiler's current zero-or-two fractions `[0, 0.5]`; serialization in Task 8 rejects any future unsupported count.

- [ ] **Step 1: Write red CPU fold parity fixtures**

For every periodic preset, compare `compiled.domain.periodic!.displayFold.applying(to:)` with the current governing `TilingStrategy.displayFold` at central/noncentral cells, negative indices, phase boundaries, reflection parity, oriented square lattices, triangular seams, and corners.

```swift
@Test(arguments: periodicFoldFixtures)
func compiledDisplayFoldMatchesGoverningKernel(fixture: PeriodicFoldFixture) throws {
    let strategy = try fixture.makeStrategy()
    let fold = try #require(strategy.compiledSymmetry.domain.periodic?.displayFold)
    for world in fixture.probes {
        #expect(fold.applying(to: world).isApproximatelyEqual(
            to: strategy.displayFold(world), tolerance: 1e-5
        ))
    }
}
```

- [ ] **Step 2: Run and confirm the serializable authority is absent**

```bash
swift test --filter 'RectangularSymmetryKernelParityTests|TriangularSymmetryKernelTests|TilingStrategyTests'
```

Expected: new tests do not compile because `CompiledPeriodicDisplayFold` is absent.

- [ ] **Step 3: Implement the normalized fold and delegate existing kernels**

Move positive modulo, phase-index parity for negative cells, repeat-to-canonical scaling, reflection parity, and unit-lattice modulo into `CompiledPeriodicDisplayFold.applying`. Construct it in `SymmetryDescriptorCompiler` from normalized compiler output. Make rectangular/triangular kernel `displayFold` delegate to this value so CPU and future wire payload have one authority. Do not switch on `SymmetryPresetID`.

- [ ] **Step 4: Re-run all PatternEngine symmetry tests**

```bash
swift test --filter PatternEngineTests
```

Expected: all PatternEngine tests pass with exact existing fold behavior.

- [ ] **Step 5: Commit compiled fold authority**

```bash
git add Sources/PatternEngine/CompiledPeriodicDisplayFold.swift Sources/PatternEngine/CompiledSymmetry.swift Sources/PatternEngine/SymmetryDescriptorCompiler.swift Sources/PatternEngine/RectangularSymmetryKernel.swift Sources/PatternEngine/TriangularSymmetryKernel.swift Sources/PatternEngine/TilingStrategy.swift Tests/PatternEngineTests/RectangularSymmetryKernelParityTests.swift Tests/PatternEngineTests/TriangularSymmetryKernelTests.swift Tests/PatternEngineTests/TilingStrategyTests.swift
git commit -m "feat: compile periodic display folds"
```

---

### Task 8: Periodic Sparse-Sampling ABI, GPU Fold, and Export Parity

**Files:**
- Create: `Sources/MetalRenderer/Display/CanvasDisplayOutputMapping.swift`
- Modify: `Sources/MetalRenderer/Compositing/SparseTileSamplingPlan.swift`
- Modify: `Sources/MetalRenderer/Compositing/SparseTileSamplingPipeline.swift`
- Modify: `Sources/MetalRenderer/Compositing/LayerCompositor.swift`
- Modify: `Sources/MetalRenderer/Compositing/LayerBlendPipeline.swift`
- Modify: `Sources/MetalRenderer/Raster/DocumentPaintRenderContext.swift`
- Modify: `Sources/MetalRenderer/Raster/DocumentPaintSurfaceStore.swift`
- Modify: `Sources/MetalRenderer/Raster/DocumentPaintStableSnapshotRenderer.swift`
- Modify: `Sources/MetalRenderer/Display/CanvasDisplayCompositor.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/CShaderTypes/include/ShaderTypes.h`
- Modify: `Sources/MetalRenderer/ShaderABI.swift`
- Modify: `Sources/MetalRenderer/Shaders.metal`
- Test: `Tests/MetalRendererTests/ShaderABILayoutTests.swift`
- Test: `Tests/MetalRendererTests/SparseTileSamplingPlanTests.swift`
- Test: `Tests/MetalRendererTests/SparseTileSamplingPipelineTests.swift`
- Test: `Tests/MetalRendererTests/DocumentPaintStableSnapshotRendererTests.swift`
- Test: `Tests/MetalRendererTests/PeriodicRepeatExportTests.swift`

**Interfaces:**
- Consumes: `CompiledPeriodicDisplayFold` from Task 7 and direct display snapshot from Task 6.
- Produces:

```swift
struct SparseTilePeriodicOutputMapping: Equatable, Hashable, Sendable {
    let fold: CompiledPeriodicDisplayFold
    let outputToWorldTransform: SparseTileOutputToSourceTransform
}

enum SparseTileSamplingOutputMappingKind: UInt8, Hashable, Sendable {
    case affine
    case periodic
    case finiteRadial
}

enum SparseTileSamplingOutputMapping: Equatable, Hashable, Sendable {
    case affine(SparseTileOutputToSourceTransform)
    case periodic(SparseTilePeriodicOutputMapping)
    case finiteRadial(SparseTileFiniteRadialOutputMapping)
}

enum CanvasDisplayOutputMapping {
    static func make(
        viewport: ViewportTransform,
        strategy: TilingStrategy,
        outputPixelSize: PixelSize
    ) throws -> SparseTileSamplingOutputMapping
}
```

Add a distinct fragment buffer index and ABI-v2 wire payload:

```c
typedef struct PatternPeriodicDisplayFoldUniforms {
    PatternFloat2 canonicalSize;
    PatternFloat2 repeatSize;
    PatternFloat2 worldToLatticeXAxis;
    PatternFloat2 worldToLatticeYAxis;
    PatternFloat2 worldToLatticeTranslation;
    PatternFloat2 phaseFractions;
    PatternUInt32 foldMode;
    PatternUInt32 symmetryFamily;
    PatternUInt32 phaseCount;
    PatternUInt32 phaseIndexAxis;
    PatternUInt32 phaseOffsetAxis;
    PatternUInt32 reflectionFlags;
    PatternUInt2 reserved;
} PatternPeriodicDisplayFoldUniforms;
```

The periodic mapping hash covers every matrix scalar, canonical/repeat scalar, phase fraction/axis/count, reflection bit, family/mode, and output transform.

- [ ] **Step 1: Write red plan identity/reachability and ABI tests**

Add tests proving periodic and affine keys cannot alias; incompatible periodic addressing fails before retaining resources; nonlinear reachability partitions output at fold-cell boundaries and preserves fallback bisection below 16 textures; ABI size/offset/version are exact; and capacity greater than two phase fractions fails closed.

```swift
@Test
func periodicMappingIdentityIncludesPhaseReflectionAndLattice() throws {
    let mappings = try SparsePeriodicFixture.semanticVariants()
    #expect(Set(mappings).count == mappings.count)
    #expect(mappings.allSatisfy { $0.kind == .periodic })
}
```

- [ ] **Step 2: Write red GPU-vs-CPU pixel oracles**

Use an asymmetric coordinate-colored canonical texture. For every periodic preset, sample both tier-2 and fallback backends at central/noncentral cells, negative phase parity, reflected cells, tile/page seams, and corners. Expected pixels come only from `CompiledPeriodicDisplayFold.applying` plus the existing bilinear oracle.

Add a stable-renderer split/unsplit byte-equality test and flattened-export asymmetric-pixel tests for half-drop, brick, mirror, oriented square, and triangular presets.

- [ ] **Step 3: Run and confirm grid-only output behavior**

```bash
swift test --filter 'ShaderABILayoutTests|SparseTileSamplingPlanTests|SparseTileSamplingPipelineTests|DocumentPaintStableSnapshotRendererTests|PeriodicRepeatExportTests'
```

Expected: ABI/mapping tests fail to compile; half-drop/brick/reflection/triangular pixel probes show rectangular-modulo output.

- [ ] **Step 4: Implement plan reachability, ABI upload, and preset-independent Metal fold**

Add one shared nonlinear reachability helper used by physical-reference selection, selected-plan construction, output-halo preflight, required-binding/slot counts, and validation. Partition output bounds at compiled fold-cell boundaries, map each piece into canonical space, add four-neighbor bilinear halo, and return exact canonical page coordinates.

Extend pipeline keys/upload leases with the periodic buffer. Bind it only for `.periodic`. In Metal, implement `patternPeriodicDisplayFold(world, fold)` with positive modulo, negative-index phase parity, repeat-to-canonical scaling, reflections, and unit-lattice modulo; route periodic tier-2/fallback normal/interchange entry points through it before existing value sampling.

Use `CanvasDisplayOutputMapping.make` from both ordinary display and `GridRenderer.exportFlattenedScene`. Stable chunk child mappings preserve the fold and apply `childTransform` only to `outputToWorldTransform`. Keep metric repeat export affine because it exports canonical repeat storage.

- [ ] **Step 5: Re-run ABI, GPU, stable renderer, and export suites**

```bash
swift test --filter 'ShaderABILayoutTests|SparseTileSamplingPlanTests|SparseTileSamplingPipelineTests|DocumentPaintStableSnapshotRendererTests|PeriodicRepeatExportTests'
```

Expected: all pass for tier-2 and fallback; split/unsplit bytes match; every tested displayed tiling matches the CPU oracle.

- [ ] **Step 6: Run the broader rendering correctness selection**

```bash
swift test --filter 'PatternEngineTests|RadialShaderTests|LayerBlendPipelineTests|DocumentPaintStableCanonicalSnapshotTests|GridCanvasContractTests'
```

Expected: all pass; finite plain/radial behavior remains unchanged.

- [ ] **Step 7: Commit compiled periodic GPU presentation**

```bash
git add Sources/MetalRenderer/Display/CanvasDisplayOutputMapping.swift Sources/MetalRenderer/Compositing/SparseTileSamplingPlan.swift Sources/MetalRenderer/Compositing/SparseTileSamplingPipeline.swift Sources/MetalRenderer/Compositing/LayerCompositor.swift Sources/MetalRenderer/Compositing/LayerBlendPipeline.swift Sources/MetalRenderer/Raster/DocumentPaintRenderContext.swift Sources/MetalRenderer/Raster/DocumentPaintSurfaceStore.swift Sources/MetalRenderer/Raster/DocumentPaintStableSnapshotRenderer.swift Sources/MetalRenderer/Display/CanvasDisplayCompositor.swift Sources/MetalRenderer/GridRenderer.swift Sources/CShaderTypes/include/ShaderTypes.h Sources/MetalRenderer/ShaderABI.swift Sources/MetalRenderer/Shaders.metal Tests/MetalRendererTests/ShaderABILayoutTests.swift Tests/MetalRendererTests/SparseTileSamplingPlanTests.swift Tests/MetalRendererTests/SparseTileSamplingPipelineTests.swift Tests/MetalRendererTests/DocumentPaintStableSnapshotRendererTests.swift Tests/MetalRendererTests/PeriodicRepeatExportTests.swift
git commit -m "fix: restore compiled tiling display"
```

---

### Task 9: Actual Drawable Presentation Telemetry and Shipping UI Regressions

**Files:**
- Modify: `Sources/MetalRenderer/StrokeRuntime/InteractiveBrushTrace.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `App/PatternSpike/Acceptance/InteractiveBrushTraceLogger.swift`
- Create: `App/UITests/InteractiveBrushPresentationUITests.swift`
- Modify: `App/project.yml`
- Test: `Tests/MetalRendererTests/StrokeRuntimeTelemetryTests.swift`
- Test: `App/Tests/InteractiveBrushTraceLoggerTests.swift`

**Interfaces:**
- Consumes: trace lineage from Task 1, pump/snapshots from Task 3, cache revisions from Tasks 4-6, and actual `CAMetalDrawable` objects.
- Produces: authoritative trace records for `.drawableSubmitted` and `.drawablePresented`; the latter uses `CAMetalDrawable.addPresentedHandler` and `presentedTime`, never command-buffer completion.

Acceptance environment:

```text
INTERACTIVE_BRUSH_ACCEPTANCE_LOG=/absolute/path/interactive-brush.jsonl
INTERACTIVE_BRUSH_ACCEPTANCE_SCENARIO=<stable scenario id>
INTERACTIVE_BRUSH_ACCEPTANCE_COMMIT=<40-hex commit>
INTERACTIVE_BRUSH_ACCEPTANCE_BINARY_SHA256=<64-hex digest>
INTERACTIVE_BRUSH_ACCEPTANCE_DURATION_SECONDS=<integer wall seconds>
```

- [ ] **Step 1: Write red actual-presentation telemetry tests**

Add a fake drawable/presentation clock seam proving command completion emits no `.drawablePresented`, while the presented handler emits exactly one record with the immutable submitted revision and all carried input identities. Assert a superseded frame cannot mark a newer revision presented.

- [ ] **Step 2: Write red shipping XCUI regressions**

Add these macOS tests against the unchanged `PatternSpikeMac` app:

```swift
func testShippingPathRecordsAuthoritativeInputThroughDrawablePresentation()
func testPausedShippingCanvasContinuesPresentingDuringSustainedStroke()
func testMaximizedWindowDrawsWithoutFullDrawableScratchOrRendererError()
func testRapidResizeZoomAndStrokePublishesOnlyCompatibleRevisions()
```

The sustained-stroke test holds a real mouse drag and polls the incrementally readable JSONL before pointer-up; it requires multiple authoritative inputs and at least two actual presented events. The maximize test requires drawable area above 4,194,304 pixels, zero interactive full-drawable scratch bytes, a presented frame, and no error banner/record. The resize test maximizes/restores and zooms during a drag, then checks revision compatibility and zero terminal ownership.

- [ ] **Step 3: Generate the project and run the red shipping tests on parent behavior**

```bash
xcodegen generate --spec App/project.yml
xcodebuild test -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -configuration Debug -destination 'platform=macOS' -only-testing:PatternSpikeMacUITests/InteractiveBrushPresentationUITests -parallel-testing-enabled NO
```

Expected on the pre-repair parent: sustained drag lacks continuation presentations, maximize produces scratch failure, resize can produce busy/inconsistent addressing, and no actual-presentation trace exists. After Tasks 3-8, only missing telemetry/project wiring should remain red.

- [ ] **Step 4: Attach actual presentation handler and Release acceptance scheme**

Call `drawable.addPresentedHandler` before `commandBuffer.present(drawable)`. Capture immutable frame/input/revision identities; in the handler record `drawable.presentedTime`, dispatch pump presentation settlement to `MainActor`, and keep command completion separately labeled. Add `PatternSpikeMacInteractiveAcceptance` in `App/project.yml` with Release test configuration, targeting the shipping `PatternSpikeMac` executable and existing UI-test bundle.

- [ ] **Step 5: Run focused telemetry and all four shipping regressions**

```bash
swift test --filter StrokeRuntimeTelemetryTests
swift test --filter InteractiveBrushTraceLoggerTests
xcodegen generate --spec App/project.yml
xcodebuild test -project App/PatternSpike.xcodeproj -scheme PatternSpikeMacInteractiveAcceptance -configuration Release -destination 'platform=macOS' -only-testing:PatternSpikeMacUITests/InteractiveBrushPresentationUITests -parallel-testing-enabled NO
```

Expected: all pass; evidence contains real presented timestamps before pointer-up and zero user-visible Metal errors.

- [ ] **Step 6: Commit shipping presentation proof**

```bash
git add Sources/MetalRenderer/StrokeRuntime/InteractiveBrushTrace.swift Sources/MetalRenderer/GridRenderer.swift App/PatternSpike/Acceptance/InteractiveBrushTraceLogger.swift App/UITests/InteractiveBrushPresentationUITests.swift App/project.yml Tests/MetalRendererTests/StrokeRuntimeTelemetryTests.swift App/Tests/InteractiveBrushTraceLoggerTests.swift App/PatternSpike.xcodeproj
git commit -m "test: prove shipping brush presentation"
```

---

### Task 10: Typed Acceptance Gate and Release Orchestration

**Files:**
- Create: `Sources/InteractiveBrushAcceptanceValidation/InteractiveBrushAcceptanceValidation.swift`
- Create: `Sources/InteractiveBrushAcceptanceGate/main.swift`
- Create: `Tests/InteractiveBrushAcceptanceValidationTests/InteractiveBrushAcceptanceValidationTests.swift`
- Create: `scripts/run-interactive-brush-presentation-acceptance.sh`
- Modify: `Package.swift`
- Modify: `App/project.yml`
- Modify: `App/UITests/InteractiveBrushPresentationUITests.swift`
- Create: `App/UITests/InteractiveBrushPadPresentationUITests.swift`

**Interfaces:**
- Consumes: incremental JSONL from Task 9, exact Git commit, exact built binary digest, `xcresult`, OS/GPU/display/backing/input metadata, and ownership/cache snapshots.
- Produces:

```swift
public struct InteractiveBrushAcceptanceThresholds: Codable, Sendable {
    public let refreshHertz: Double
    public let inputToSubmitP95Milliseconds: Double
    public let inputToSubmitP99Milliseconds: Double
    public let inputToPresentP95RefreshIntervals: Double
    public let inputToPresentP99RefreshIntervals: Double
    public let maximumInputToPresentMilliseconds: Double
    public let maximumMissedDeadlineFraction: Double
    public let maximumConsecutiveMisses: Int
    public let maximumFinalRSSSlopeMiBPerMinute: Double
}

public struct InteractiveBrushAcceptanceResult: Codable, Sendable {
    public let passed: Bool
    public let failures: [String]
    public let measuredWallSeconds: Double
    public let recordCount: Int
}

public enum InteractiveBrushAcceptanceValidator {
    public static func validate(
        records: [InteractiveBrushTraceRecord],
        metadata: InteractiveBrushAcceptanceMetadata,
        thresholds: InteractiveBrushAcceptanceThresholds
    ) -> InteractiveBrushAcceptanceResult
}
```

For 120 Hz, submit p95/p99 limits are 8/12 ms; for 60 Hz they are 12/16.7 ms. Present p95/p99 limits are two/three refresh intervals, every authoritative sample is at most 100 ms, missed deadlines are at most 1% with no run above two, brush preparation p95 is below 2 ms, backlog settles within two refresh intervals, and final-five-minute RSS slope is at most 1 MiB/min with post-settle RSS within the larger of 10% or 64 MiB of warm baseline.

- [ ] **Step 1: Write red fail-closed evidence-validator tests**

Use fixed JSONL fixtures to prove pass/fail boundaries, exact commit/binary identity, no missing authoritative stages, no offscreen-completion substitution, no dropped/reordered inputs, real 600-second duration, stable backlog, error absence, zero ownership, cache budget, RSS slope, and hardware metadata. A missing field or unknown schema version must fail.

- [ ] **Step 2: Run and confirm the validation target is absent**

```bash
swift test --filter InteractiveBrushAcceptanceValidationTests
```

Expected: target/types are absent.

- [ ] **Step 3: Implement the typed validator and CLI**

Add a library/test/executable target to `Package.swift`. The CLI accepts `--run-directory`, reads metadata and JSONL, emits a deterministic JSON result, prints each failure, and exits nonzero on any invalid/missing evidence. Keep threshold math in the library and cover exact boundary values.

- [ ] **Step 4: Write the Bash 3.2-compatible runner**

The script must:

1. Require a clean tracked tree and resolve the full commit.
2. Generate the Xcode project.
3. Build-for-testing the shipping app/UI tests in Release.
4. Hash the exact launched `PatternSpike.app/Contents/MacOS/PatternSpike` binary with `shasum -a 256`.
5. Run the four short shipping regressions as smoke.
6. Run `testTrueTenMinuteMixedShippingSession` for 600 measured wall seconds at 2048x2048, then separately at 4096x4096.
7. Poll the JSONL heartbeat at least every five seconds and terminate a stalled run while preserving evidence.
8. Repeat correctness/ownership with Metal validation enabled; run latency with it disabled.
9. Preserve JSONL, stdout/stderr, `.xcresult`, validation JSON, commit/digest, OS/GPU/display/backing/input metadata, and exact commands.
10. Label every shortened duration `SMOKE ONLY — NOT ACCEPTANCE` and forbid it from producing `passed: true`.

Use explicit run-directory paths under `.build/interactive-brush-acceptance/<commit>/<timestamp>/`; do not delete prior runs.

- [ ] **Step 5: Add the true-duration UI route and iPad acceptance target**

Implement `testTrueTenMinuteMixedShippingSession` as real pointer input, zoom, pan, layer edits, half-drop/brick/reflection/triangular tilings, resize where supported, commit/cancel, and idle checks driven until `ContinuousClock` reaches the environment-specified duration. It must not call renderer offscreen flush APIs.

Add `PatternSpikePadUITests` and `PatternSpikePadInteractiveAcceptance` to `App/project.yml`, targeting the shipping iPad app and the same trace/evidence contract. The iPad test uses XCTest coordinate drags and requires physical device destinations supplied to the runner.

- [ ] **Step 6: Run validator unit tests and script syntax checks**

```bash
swift test --filter InteractiveBrushAcceptanceValidationTests
bash -n scripts/run-interactive-brush-presentation-acceptance.sh
xcodegen generate --spec App/project.yml
xcodebuild -list -project App/PatternSpike.xcodeproj
```

Expected: validator tests pass; Bash syntax is valid under the system Bash; both macOS and iPad acceptance schemes are listed.

- [ ] **Step 7: Run Release smoke acceptance**

```bash
INTERACTIVE_BRUSH_ACCEPTANCE_SMOKE_SECONDS=30 scripts/run-interactive-brush-presentation-acceptance.sh --mac-smoke
```

Expected: the runner clearly labels the result non-acceptance, preserves live JSONL/xcresult, reports a heartbeat during execution, and all functional smoke gates pass.

- [ ] **Step 8: Commit the acceptance gate**

```bash
git add Package.swift Sources/InteractiveBrushAcceptanceValidation Sources/InteractiveBrushAcceptanceGate Tests/InteractiveBrushAcceptanceValidationTests scripts/run-interactive-brush-presentation-acceptance.sh App/project.yml App/UITests/InteractiveBrushPresentationUITests.swift App/UITests/InteractiveBrushPadPresentationUITests.swift App/PatternSpike.xcodeproj
git commit -m "test: gate interactive brush release"
```

---

### Task 11: Broad Verification, True Endurance, Review, and Evidence Update

**Files:**
- Modify: `docs/superpowers/reports/2026-08-04-stage-d-acceptance.md`
- Modify: `docs/superpowers/plans/2026-08-04-stage-d-finalization.md`
- Modify: `docs/superpowers/plans/2026-08-13-interactive-brush-presentation-repair.md`
- Create: `docs/superpowers/reports/2026-08-13-interactive-brush-presentation-acceptance.md`
- Evidence: `.build/interactive-brush-acceptance/<commit>/<timestamp>/`

**Interfaces:**
- Consumes: exact Release runner and validator from Task 10 plus all focused behavioral suites.
- Produces: exact-commit automated evidence, independent code-review disposition, updated project status, and a clearly enumerated physical-hardware qualification remainder if devices are unavailable.

- [ ] **Step 1: Run formatting/diff and full Swift suites from a clean tracked tree**

```bash
git diff --check
swift test
xcodegen generate --spec App/project.yml
xcodebuild test -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO
```

Expected: clean diff check and all Swift/app tests pass. Preserve full logs and exact test counts.

- [ ] **Step 2: Run targeted stress loops for prior races**

Run each gated cache ACK, frame-pump retirement, large-drawable, resize/zoom/stroke, and periodic GPU parity test 25 times without rebuilding between iterations. Any failure restarts diagnosis; do not average it away.

```bash
for iteration in $(seq 1 25); do
  swift test --skip-build --filter 'InteractiveStrokePresentationCacheTests|InteractiveFrameTimestampTests|GridRendererSparseCutoverTests|CanvasPresentationCacheTests|SparseTileSamplingPipelineTests' || exit 1
done
```

Expected: 25/25 iterations pass with zero hangs, retries, or skipped tests.

- [ ] **Step 3: Run the true macOS Release acceptance twice**

```bash
scripts/run-interactive-brush-presentation-acceptance.sh --mac-acceptance
MTL_DEBUG_LAYER=1 scripts/run-interactive-brush-presentation-acceptance.sh --mac-validation
```

Expected: the timing run completes two separate 600-wall-second 2048/4096 sessions and meets all latency/backlog/memory/error/ownership gates; the validation run meets correctness and ownership gates without being used for timing claims.

- [ ] **Step 4: Inspect preserved evidence before documenting results**

Verify exact commit and binary digest, actual duration, live heartbeat continuity, every authoritative identity's ordered stages, actual drawable presentation, all cache/ownership counters at zero, no error records, tiling pixel hashes, RSS calculations, and `.xcresult` pass/skip counts. Decode at least one asymmetric half-drop and brick frame and compare its stored pixels with the CPU fold oracle.

- [ ] **Step 5: Obtain independent code and evidence review**

Use `superpowers:requesting-code-review` against the full parent-to-candidate diff. Require explicit Critical/Important/Minor counts, exact commit/tree identity, and independent reruns of the shipping sustained-drag, maximized-window, resize/zoom, and tiling pixel tests. Resolve every Critical and Important finding with a new red/green cycle; document Minor disposition.

- [ ] **Step 6: Update status and acceptance reports accurately**

Record commands, exact counts, commit, binary digest, hardware, refresh rate, canvas sizes, measured latency/backlog/RSS, ownership settlement, tiling matrix, and review counts. Mark the old Stage D performance evidence superseded where it used offscreen or accelerated paths. Do not call macOS automated evidence final physical qualification.

- [ ] **Step 7: Commit and push the reviewed automated repair**

```bash
git add docs/superpowers/reports/2026-08-04-stage-d-acceptance.md docs/superpowers/plans/2026-08-04-stage-d-finalization.md docs/superpowers/plans/2026-08-13-interactive-brush-presentation-repair.md docs/superpowers/reports/2026-08-13-interactive-brush-presentation-acceptance.md
git commit -m "docs: record brush presentation acceptance"
git push origin main
```

Expected: `git rev-parse HEAD`, local `origin/main`, and `git ls-remote origin refs/heads/main` all resolve to the same reviewed commit; tracked tree is clean.

- [ ] **Step 8: Run the physical hardware qualification matrix**

Run the same exact commit/binary evidence contract on a lowest-supported 60 Hz Apple-silicon Mac with mouse, a current 120 Hz Apple-silicon Mac with mouse, an A14-class 60 Hz iPad with Apple Pencil, and an M-series 120 Hz iPad with Apple Pencil. Exercise 1x/2x backing scale and 0.25x/1x/8x zoom for every supported tiling. This is the only step that may require the project owner's physical-device access; preserve each device's evidence separately and update the report without weakening missing-device status.

---

## Execution Order and Review Gates

1. Tasks 1 and 7 may be developed in parallel because trace lineage and the PatternEngine fold do not share files.
2. Task 2 precedes Tasks 3-6 because all cache/snapshot keys require context-owned canonical identity.
3. Task 3 precedes Task 4 so cache publication has a correct paused-view demand consumer.
4. Tasks 4 and 5 may be reviewed independently, but both must pass before Task 6 removes ordinary `LayerCompositor` display.
5. Task 8 requires Tasks 6 and 7 so both direct display and compiled fold authority exist.
6. Task 9 requires Tasks 1, 3, 6, and 8; Task 10 requires Task 9; Task 11 is the final verification/review/evidence gate.
7. After every task, run `git diff --check`, inspect unrelated changes, and request a behavioral review before moving to the next dependency boundary.

## Spec Coverage Review

- Worker/drawable decoupling and exact settlement: Tasks 4 and 6.
- Dirty-proportional canonical and transient work with bounded memory: Tasks 4-6.
- No ordinary full-drawable scratch: Task 6 plus shipping proof in Tasks 9-11.
- Immutable geometry/tiling/layer/transient/viewport/drawable revisions and latest-wins retirement: Tasks 2-3 and 6.
- Complete CPU/GPU fold and flattened export parity: Tasks 7-8.
- Frame starvation repair without permanent render loop: Task 3.
- Per-input event-to-present production telemetry and incremental progress: Tasks 1 and 9.
- Correct failure classification and zero idle ownership: Tasks 3-6 and validator Task 10.
- Exact Release executable, latency/backlog/deadline/RSS/endurance gates: Tasks 9-11.
- Physical Mac/tablet qualification and 1x/2x plus 0.25x/1x/8x matrix: Task 11.
- Krita replacement, new brush families, and brush-feel retuning remain excluded by Global Constraints.
