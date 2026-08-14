# Interactive Brush Presentation Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the shipping Swift/Metal canvas responsive, bounded, and pixel-correct by decoupling brush-worker progress from drawable presentation, presenting persistent tile caches through the compiled symmetry fold, and proving the result in the actual Release app.

**Architecture:** Preserve the existing brush generator, sparse stroke surfaces, document transaction authority, history model, and export compositor. Add context-authenticated transient and canonical/projected presentation caches, publish immutable revision-compatible presentation roots, and use a paused-view frame pump to render a merged direct display view or a bounded whole-frame tiled-exact fallback on admitted hardware; retain an explicitly named legacy startup mode below that capability. Serialize the compiled periodic fold into the sparse sampling ABI instead of switching on tiling preset identifiers.

**Tech Stack:** Swift 6, Swift Testing/XCTest, Metal/MetalKit, Core Animation drawable presentation callbacks, XcodeGen, Bash 3.2-compatible acceptance scripts, JSONL evidence, macOS 14+, iPadOS 18+.

## Global Constraints

- Work on `main`; preserve unrelated untracked `.vscode/` and `brushes/procreate/1_FREE_Charcoal_Set.key` content.
- Do not replace the brush generator, dynamics engine, compiled symmetry model, sparse document store, history model, project format, or Metal deposition backend.
- Drawable availability, display preparation, and presentation completion must never grant brush-input or deposition-worker credit.
- Authoritative input must never be dropped, duplicated, reordered, or replaced by prediction; prediction must not change the settled canonical document hash.
- Every GPU-owned prepared stroke resource must settle exactly once through cache adoption, cancellation, or failure.
- In admitted tiled/direct capability, ordinary drawing work must be proportional to dirty canonical tiles and affected presentation regions, never full document area, and must allocate no three-texture full-drawable scratch set. Below the explicit tiled threshold, legacy startup behavior is preserved and is not counted as satisfying this guarantee.
- One immutable presentation snapshot must supply geometry, tiling, layer, transient, viewport, backing-scale, and drawable revisions to a frame.
- CPU and GPU display folds must agree for every compiled periodic and finite symmetry family; do not add a shader preset-ID switch or a second tiling table.
- On admitted tiled/direct hardware, the old full-output `LayerCompositor` path
  remains available for stable capture/export only. Qualified ordinary
  `draw(in:)` uses one merged D source or the shared <=256² tiled-exact kernel
  and allocates no full-drawable scratch. Explicit below-threshold
  `.legacyLayered` may retain the shipping path solely to preserve startup.
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
    public let mappingPrepassWaveCount: UInt16?
    public let serializedChildCommandCount: UInt64?
    public let coveredLayerPixelCount: UInt64?
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

### Task 6: Projected Preview Replacement and Atomic Direct Display

> **Approved architecture amendment (2026-08-14).** The original proposal to
> sample flattened canonical content plus a raw active-layer transient overlay
> is invalid for a layered document. A top-layer erase would erase the flattened
> lower result, a lower-layer stroke would appear above stable upper layers, and
> layer opacity/blend semantics could not be reconstructed. Task 6 therefore
> uses stable flattened canonical tiles `F` plus bounded, fully projected dirty
> replacement tiles `P`.

**Files:**
- Create: `Sources/MetalRenderer/Display/CanvasProjectedPreviewTileCache.swift`
- Create: `Sources/MetalRenderer/Display/CanvasPresentationRoot.swift`
- Create: `Sources/MetalRenderer/Display/CanvasPresentationTileStoreCore.swift`
- Create: `Sources/MetalRenderer/Display/CanvasPresentationWorkspaceArena.swift`
- Create: `Sources/MetalRenderer/Display/CanvasTiledExactDisplayCompositor.swift`
- Modify: `Sources/MetalRenderer/Display/CanvasPresentationSnapshot.swift`
- Modify: `Sources/MetalRenderer/Display/CanvasDisplayCompositor.swift`
- Modify: `Sources/MetalRenderer/Display/InteractiveStrokePresentationCache.swift`
- Modify: `Sources/MetalRenderer/Display/CanvasCompositeTileCache.swift`
- Modify: `Sources/MetalRenderer/Compositing/LayerCompositor.swift`
- Create: `Sources/MetalRenderer/Compositing/SparseTileExactRadialReachabilityPipeline.swift`
- Create: `Sources/MetalRenderer/Compositing/CanvasPresentationSparsePlanBuilder.swift`
- Create: `Sources/MetalRenderer/Compositing/SparseTileSamplingGPUHostArena.swift`
- Create: `Sources/MetalRenderer/Compositing/SparseTileSamplingGPUPhysicalArena.swift`
- Modify: `Sources/MetalRenderer/Compositing/SparseTileSamplingPlan.swift`
- Modify: `Sources/MetalRenderer/Compositing/SparseTileSamplingPipeline.swift`
- Modify: `Sources/MetalRenderer/Compositing/DocumentPaintVisiblePlanController.swift`
- Modify: `Sources/MetalRenderer/Shaders.metal`
- Modify: `Sources/MetalRenderer/Raster/DocumentPaintRenderContext.swift`
- Modify: `Sources/MetalRenderer/Raster/DocumentPaintSurfaceStore.swift`
- Modify: `Sources/MetalRenderer/Raster/PaintTileStore.swift`
- Modify: `Sources/MetalRenderer/Raster/TiledRasterSurface.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Test: `Tests/MetalRendererTests/CanvasPresentationCacheTests.swift`
- Test: `Tests/MetalRendererTests/GridRendererSparseCutoverTests.swift`
- Test: `Tests/MetalRendererTests/InteractiveStrokePresentationCacheTests.swift`
- Test: `Tests/MetalRendererTests/CanvasCompositeTileCacheTests.swift`
- Test: `Tests/MetalRendererTests/LayerCompositorTests.swift`
- Test: `Tests/MetalRendererTests/PaintTileResidencyTests.swift`
- Test: `Tests/MetalRendererTests/PaintTileSnapshotRetentionTests.swift`
- Test: `Tests/MetalRendererTests/SparseTileSamplingPlanTests.swift`
- Test: `Tests/MetalRendererTests/SparseTileSamplingPipelineTests.swift`
- Test: `Tests/MetalRendererTests/StageDAcceptanceTests.swift`

**Interfaces:**
- Consumes: the Task 3 pump/revision machinery, actor-confined exact-revision
  Task 4 projection metadata plus an invalidation fence and restricted child
  lease factory, a Context/SurfaceStore-issued exact ordered-layer projection
  plan, a snapshot-scoped Task 5 sparse-source borrow, and the already completed
  Task 8 output-mapping/fold ABI.
- Produces: one jointly budgeted F/P presentation-tile store with separate
  logical namespaces, an atomically published direct-or-tiled-exact presentation
  root, zero-copy authenticated final-P promotion, and durable retry debt after
  irreversible document publication only when a pre-reserved F/direct claim
  still requires completion.

```swift
struct CanvasProjectedPreviewRevision: Equatable, Sendable {
    let transient: InteractiveStrokePresentationRevision
    let canonicalBaseRevision: CanvasCompositeRevision
    let sequence: UInt64
}

/// Opaque, authority-minted, process-global monotonic, and non-ABA. Counter
/// overflow rejects before minting. Equality is exact identity,
/// never digest equality; its authority owns the full immutable geometry tuple
/// and canonical algorithmic coordinate-index rule in fixed R_m metadata.
struct CanvasTileDomainIdentity: Equatable, Hashable, Sendable {
    fileprivate let authorityGeneration: UInt64
    fileprivate let domainSequence: UInt64
}

/// Noncopyable inline value. Set/Dictionary/Array storage is forbidden. The
/// authority requires the domain's exact bitCount, rejects bitCount > 1,024 and
/// any set tail bit at index >= bitCount, and zeroes inactive lanes. Equality is
/// an explicit exact word comparison after domain+bitCount equality; digest
/// equality is never authority.
struct CanvasTileDomainBits: ~Copyable, @unchecked Sendable {
    let domain: CanvasTileDomainIdentity
    let bitCount: UInt16
    private let words: SIMD16<UInt64>
    var wordCount: UInt8 { get }
    func isEqual(to other: borrowing Self) -> Bool
}

final class CanvasProjectedPreviewSnapshot: @unchecked Sendable {
    let revision: CanvasProjectedPreviewRevision
    // Borrows the fixed P-publication record; owns no bit payload copy.
    func withExplicitlyPresentCoordinates<R>(
        _ body: (borrowing CanvasTileDomainBits) throws -> R
    ) throws -> R
    func close()
}

struct CanvasExactReachabilityClaim: ~Copyable, @unchecked Sendable {
    let outputMapping: SparseTileSamplingOutputMapping
    let outputRegion: SparseTileOutputRegion
    let addressingRevision: UInt64
    let physicalCoordinates: CanvasTileDomainBits
    let digest: UInt64
}

enum CanvasPresentationMode: ~Copyable, @unchecked Sendable {
    case legacyLayered(CanvasLegacyLayerPlan)
    case directProjected(
        display: CanvasDisplayTileSnapshot,
        reachability: CanvasExactReachabilityClaim
    )
    case tiledExact(CanvasTiledExactLayerPlan)
}

final class CanvasDisplayTileSnapshot: @unchecked Sendable {
    let canonicalRevision: CanvasCompositeRevision
    let previewRevision: CanvasProjectedPreviewRevision?
    func borrow() throws -> CanvasDisplayTileBorrow
    func close()
}

struct CanvasExactChildPageSelection: ~Copyable, @unchecked Sendable {
    let outputRegion: SparseTileOutputRegion
    let reachabilityIdentity: UInt64
    let physicalPages: CanvasTileDomainBits
    let physicalPageCount: UInt16
}

struct CanvasQualifiedChildStreamReceipt: Equatable, Sendable {
    let mappingPrepassWaveCount: UInt16
    let serializedChildCommandCount: UInt64
    let coveredLayerPixelCount: UInt64
    let partitionDigest: UInt64
}

struct CanvasPresentationSparseOwnerClaim: ~Copyable, @unchecked Sendable {
    let rootScopeGeneration: UInt64
    // Owns one fixed owner record and R_m binding slice.
}

struct CanvasPresentationSparseSourceLease: ~Copyable, @unchecked Sendable {
    let bindingCount: UInt16
    // The pipeline reads the fixed internal slice; no array/request escapes.
    consuming func close()
}

final class CanvasDisplayTileBorrow: @unchecked Sendable {
    let canonicalRevision: CanvasCompositeRevision
    let previewRevision: CanvasProjectedPreviewRevision?
    func acquireCanonicalChild(
        selection: consuming CanvasExactChildPageSelection,
        addressing: SparseTileAddressing,
        owner: borrowing CanvasPresentationSparseOwnerClaim
    ) throws -> CanvasPresentationSparseSourceLease
    func close()
}

final class CanvasPresentationRoot: @unchecked Sendable {
    let revision: CanvasPresentationRevision
    let canonicalIdentity: CanvasCanonicalStateIdentity
    private let mode: CanvasPresentationMode
    let outputMapping: SparseTileSamplingOutputMapping
    let viewport: ViewportTransform
    let drawablePixelSize: PixelSize
    let backingScaleRevision: UInt64
    let showGridLines: Bool
    let showCanvasBoundary: Bool

    func borrow() throws -> CanvasPresentationRootBorrow
    fileprivate func withMode<R>(
        _ body: (borrowing CanvasPresentationMode) throws -> R
    ) throws -> R
}

final class CanvasPresentationRootBorrow: @unchecked Sendable {
    let revision: CanvasPresentationRevision
    let canonicalIdentity: CanvasCanonicalStateIdentity
    let outputMapping: SparseTileSamplingOutputMapping
    let viewport: ViewportTransform
    let drawablePixelSize: PixelSize
    let backingScaleRevision: UInt64
    let showGridLines: Bool
    let showCanvasBoundary: Bool
    func withMode<R>(
        _ body: (borrowing CanvasPresentationMode) throws -> R
    ) throws -> R
    func close()
}

struct CanonicalPresentationPublicationClaim: ~Copyable, @unchecked Sendable {
    let baseIdentity: CanvasCanonicalStateIdentity
    let targetIdentity: CanvasCanonicalStateIdentity
    // SurfaceStore-only construction; owns deferred replaced-source retirement.
}

struct CanvasPreparedCanonicalRootTransition: ~Copyable, @unchecked Sendable {
    let expectedRevision: CanvasPresentationRevision
    let successorRevision: CanvasPresentationRevision
    // Owns the reserved root slot, closed-gate token, and publication claim.
}

struct InteractiveStrokePreparedVersionPublication: ~Copyable, @unchecked Sendable {
    let revision: InteractiveStrokePresentationRevision
    // Owns unpublished role views and prepared displaced-reference retirement.
}

enum CanvasPreparedTask4Transition: ~Copyable, @unchecked Sendable {
    case directVersionOnly(InteractiveStrokePreparedVersionPublication)
    case rooted(
        version: InteractiveStrokePreparedVersionPublication,
        expectedRootRevision: CanvasPresentationRevision,
        successor: CanvasPresentationRoot
    )
}

@MainActor
final class CanvasPresentationRootStore {
    func publish(expected: CanvasPresentationRevision?,
                 successor: CanvasPresentationRoot) throws
    func prepareCanonicalTransition(
        expected: CanvasPresentationRevision,
        successor: CanvasPresentationRoot,
        claim: consuming CanonicalPresentationPublicationClaim
    ) throws -> CanvasPreparedCanonicalRootTransition
    // Total/nontrapping: all CAS, slot, source, and retirement checks happened
    // before Context publication; the coordinator gate prevents interleaving.
    func armAfterContextPublication(
        _ prepared: consuming CanvasPreparedCanonicalRootTransition
    )
    func cancelBeforeContextPublication(
        _ prepared: consuming CanvasPreparedCanonicalRootTransition
    )
    func borrowCurrent() throws -> CanvasPresentationRootBorrow
    func awaitRetirement(ofProjectedRevision revision:
        CanvasProjectedPreviewRevision) async
}

@MainActor
final class CanvasPresentationCoordinator {
    func prepareDirectTask4Version(
        expectedRoot: CanvasPresentationRevision,
        version: consuming InteractiveStrokePreparedVersionPublication
    ) throws -> CanvasPreparedTask4Transition
    func prepareRootedTask4Transition(
        expected: CanvasPresentationRevision,
        successor: CanvasPresentationRoot,
        version: consuming InteractiveStrokePreparedVersionPublication
    ) throws -> CanvasPreparedTask4Transition
    // Direct case swaps only the Task4 role view; rooted tiled/legacy case also
    // arms the successor. Both request old-ref retirement and enable ACK.
    func armAfterTask4Copy(
        _ prepared: consuming CanvasPreparedTask4Transition
    )
    func cancelBeforeTask4Arm(
        _ prepared: consuming CanvasPreparedTask4Transition
    )
}

final class CanvasDisplaySubmission: @unchecked Sendable {
    let revision: CanvasPresentationRevision
    func markEncoding() throws
    func markSubmitted() throws
    func markTerminal(_ disposition: CanvasDisplayTerminalDisposition)
}
```

The root borrow owns the root lifetime and exposes its noncopyable mode only
through the nonescaping `withMode` borrow. A direct callback may acquire one
`CanvasDisplayTileBorrow`; no reachability bitset or mode value is copied out.
Both mode and P-presence borrow accessors return a typed closed/stale error after
owner close; they never trap or manufacture a dangling borrow.
A canonical child is valid only while that tile/root borrow remains open; a
prepared submission transfers the root borrow and closes it only after both
resource-return and terminal ownership settle.
`CanvasDisplayTileBorrow` never manufactures the legacy heap-backed
`SparseTileSourceRequest`; exact child acquisition writes directly into the
owner's fixed slice and returns only the noncopyable fixed lease.
`prepareCanonicalTransition` is the only source-dependent canonical publication
seam. Its consuming prepared token makes `armAfterContextPublication` a
nonawaiting, nonthrowing, nontrapping field/root swap plus claim completion and
deferred-retirement request; cancellation is legal only before Context publishes.
The analogous prepared Task 4 token owns candidate role-view state. In direct
mode its arm swaps only the role view and enables ACK; the old D/root revision and
GPU scope remain current until matching P publishes. In tiled/legacy its rooted
case atomically swaps the role view and arms the prepared successor. Both are the
sole nonawaiting/nonthrowing/nontrapping lock section after GPU copy; all
allocation, copy, validation, and rooted-slot failure precedes it.

Task 4's exact projection descriptor freezes its complete
`InteractiveStrokePresentationRevision` (generation, epoch UUID, sequence),
canonical identity, active layer, exact dirty coordinates, authoritative and
prediction providers, and the same immutable material later used by commit:
composite mode, stroke opacity, accumulation limit, eraser strength, layer
opacity, and layer blend mode. It owns frozen provider/reference metadata and an
invalidation fence, not a full-set payload token. Its internal child factory
restricts to <=8 exact Task 4 refs, creates a capture, borrows and leases, then
closes borrow/capture immediately; only the lease escapes to command terminal.
Derive the stroke material once at stroke begin, retain it on the active stroke,
and pass that identical value to every Task 4 adoption and later commit; never
re-read mutable active-stroke state during projection or cutover.

The generic finite-radial Task 8 region authority intentionally carries a 3x3
logical-page seam halo and cannot prove Task 6 fallback binding or Task 4 debt
bounds: one pixel can select more than 16 role-qualified refs. Task 6 adds a
mapping-only GPU exact-radial child authority rather than a nominal CPU mirror. A shared,
non-inlined precise helper (reassociation/contraction/fast transcendental math
disabled) accepts the same root-local integer output coordinate in both stages,
synthesizes `Float(pixel)+0.5`, and performs the radial fold, `point - 0.5`, four
integer neighbors, and physical page-index lookup in both the mapping prepass
and sampling fragment. The prepass owns no Task 4 payload ref and atomically
records one 1,024-bit physical-page set for each candidate region. After command
terminal, the host revalidates Task 4/mapping revision and either acquires the
role-qualified refs or bisects; a leaf is final only when the mapping-only
physical page-set count is <=4, regardless of which role refs are absent. A one-pixel set contains at most four physical
pages, so canonical+authoritative+prediction contains at most 12 bindings and
the Task 4 retired-version subset contains at most eight; fallback's 16 slots
admit both. Every co-sampled source request—not only the two transient roles—is
restricted by that same authenticated set and final plan validation.

This authority is normative for every finite-radial Task 6 operation: visible
reachability/P materialization, canonical-only direct D children, every tiled or
legacy stable/active-layer child, and final source selection/preflight/slot
validation. The reachability claim authenticates its exact wave/page-set digest.
The generic 3x3 Task 8 authority remains available to non-Task6 capture/export
callers but may not silently re-enter qualified ordinary display.

The prepass uses one fixed four-way 256² quadtree: 87,381 nodes × 128 bytes =
11,184,768 bytes of page bitsets. Node queues/flags are capped at 524,288 bytes,
the final 65,536 child descriptors are exactly 16 bytes each = 1,048,576 bytes,
and counters/alignment are capped at 262,144 bytes, for a checked prepass peak of
13,019,776 bytes. Each 16-byte descriptor contains four `UInt16` region fields
plus four `UInt16` physical-page indices (unused entries are `UInt16.max`), and
its layout is frozen by test. A prepass wave processes a deterministic group of
<=256² output tiles, sequentially reuses the quadtree scratch with explicit
barriers, and appends final leaves to that descriptor buffer. If a multi-tile
group overflows, it has acquired no Task 4 ref and is bisected/retried by tile
group until each wave fits; one tile always fits because it has at most 65,536
pixel leaves. Thus overflow is flow control, not a permanently unrenderable
qualified revision. `CanvasPresentationWorkspaceArena` owns one physically
reserved 16 MiB `MTLHeap` with `type=.placement`, `storageMode=.shared`, and one
fixed placement table; neither the radial pipeline nor LayerCompositor may create
a Task 6 workspace resource outside it. One fixed 1 MiB descriptor range and one
phase-exclusive 15 MiB range form its complete layout. During prepass, the
descriptor range plus 11,971,200 bytes of the shared range hold the exact
13,019,776-byte tree/queue/counter peak. After a wave terminal, those placement
resources become aliasable while the descriptor range remains, and the exact
15 MiB compositor profile reuses the shared range. Before the next prepass wave,
every compositor plan/scratch allocation is terminal, evicted from its phase
cache, and returned to that same heap; Swift/Metal object release is not accepted
as physical accounting.

Before heap creation, query `heapBufferSizeAndAlign` and
`heapTextureSizeAndAlign` for every resource descriptor in both phase layouts,
checked-align every fixed offset, prove the descriptor plus the larger phase ends
at or below W, and reserve W in the global authority. Then create the placement
heap once, require `heap.size == W` and `heap.currentAllocatedSize <= W`, and
create each buffer/texture only with the placement `offset:` API. Every resource
must report `resource.heap === workspaceHeap`, the expected `heapOffset`, and an
`allocatedSize` no larger than its quoted placement range. A quote/layout that
exceeds W rejects tiled capability before heap allocation; heap failure has zero
child resources; an out-of-heap or standalone workspace allocation is rejected
before creation. Physical high-water counts the underlying heap once, not both
heap and aliased resources. A partial placement failure destroys the unpublished
heap. No upload/
readback double buffer exists, and zeroing plus terminal cleanup are included in
the 262,144-byte allowance. No `Data`, `Set`, full-frame pixel map, pending CPU
traversal stack, or unbounded child list is created, and the arena's causal
physical high-water may not exceed W=16 MiB across any number of waves. A forced
    two-wave test must warm the compositor slice to 15 MiB, return it, start the next
    13,019,776-byte prepass, and prove no overlap or out-of-arena allocation.
Below-threshold legacy uses the same fixed-capacity
authority from its already admitted shipping scratch and does not thereby claim
tiled capability. Affine/periodic reuse their already-proven exact Task 8
authorities. Rendered waves target one unpublished frame/P result; any later
wave failure or revision change discards the whole result, never a partial
publication. Cancellation/staleness publishes nothing and needs no Task 4 ACK.
Lock the maximum node/batch count, the 15 MiB maximum-layer compositor profile,
and prepass-to-sampling page-set parity at radial ray, page, center, and corner
seams on both GPU backends. For the 3024x1964 acceptance mappings, lock a maximum
of eight *mapping-prepass waves* (versus 96 output tiles). That counter is
independent of the later serialized render-command count; measure both in the
Task 10 frame budget. The one-tile prepass wave remains only the exact worst-case
path.

`DocumentPaintRenderContext.prepareProjectedPreviewTileUpdatePlan` asks
`DocumentPaintSurfaceStore` to freeze one current registry epoch and ordered
layer stack as provider/reference metadata plus an invalidation fence, not a
long-lived payload capture. Its internal child factory restricts and acquires all
stable+Task4 sources atomically, closes capture tokens immediately after exact
leases are installed, and revalidates the epoch. For
each transient-dirty coordinate it produces stable layers
below, the active stable source plus authoritative/prediction sources using the
captured material, then stable layers above. The existing bounded tile compositor
accepts a shared internal `LayerCompositeTilePlan` abstraction for both Task 5
canonical plans and preview plans; Task 6 must not duplicate blend/erase kernels.

The output `P` tile is the complete visible result for that coordinate, not a
raw layer delta. Every P result is a whole 256² canonical-storage RGBA16F tile
composed at identity raw-storage mapping and canonical pixel centers. Viewport
and Task 8 reachability choose which canonical coordinates to materialize; they
never make P screen-space, scissored, BGRA8, or viewport-dependent. Work is
`O(dirty tiles × visible layers)`, chunked with tile-sized scratch.

The projection coordinator accumulates every adopted update's changed target
coordinates until a `P` revision publishes. It reprojects the accumulated
changes intersected with the current authoritative∪prediction footprint and
removes coordinates no longer present without recomposition. Failed/stale
candidates retain the accumulator; successful publication clears only through
the exact projected Task 4 revision.

F and P are distinct logical namespaces in one actor-confined
`CanvasPresentationTileStoreCore`, with one presentation layer ID and distinct
physical surface IDs/generations. Let `T = 524,288` bytes per RGBA16F tile,
`N_F` be the exact admitted geometry page bound, `Q = 9 MiB`,
`M_5 = 2,172,928` bytes preserve Task 5's existing snapshot-metadata
entitlement, `R_m = 2,359,296` bytes be a new bounded root/provider metadata
partition, `G_m = 2,359,296` bytes be a separate fixed sparse-GPU host-metadata
arena, `C_m = 524,288` bytes be one fixed ephemeral CPU-plan builder arena, and
`N_m = 1,024` be the fixed defensive metadata-domain capacity regardless of
actual geometry, and
`V = currentTransientFootprint ∩ exactTask8Reachability`; existing Task 4
admission bounds its unique coordinates by `min(N_F, 682)`. The shared store's
closed capacity is `2 * N_F * T + Q`: `2 * N_F * T` is resident capacity and Q
is reserved exclusively for the persistent-zero plus an at-most-eight-tile
upload/readback/staging wave. One allocationless command-terminal arbiter
serializes every Task 4-sampling presentation child across P, tiled, and legacy;
P/tiled plus F composition additionally serialize the single 16 MiB tile
workspace, while legacy uses only its shipping full-output scratch. Initial
`F + P` and hybrid commit
`oldF + promotedP + composed(target − V)` fit within `2N_F`. Incremental P
updates reuse unchanged exact P references. Before reduction, every changed
coordinate is admitted as a full T-byte destination in at-most-eight-tile
chunks; authenticated clear reduction releases the destination and records
presence-only metadata. The store's locked admission deduplicates exact
`PaintTileIdentity` values and counts the actual bytes held by F,
current/candidate P, D captures, pending retirement, backing, cleanup debt,
persistent zero, and provisional transfer; coordinate-count preflight never
replaces that authority.

`T`, `C_v=T/2`, and Q are physical Metal strides, not requested logical lengths.
Before tiled/direct admission, freeze the exact storage mode, usage, pixel format,
dimensions, and hazard options for color, coverage, persistent-zero, and transfer
resources. Query `heapTextureSizeAndAlign`/`heapBufferSizeAndAlign`; require color
and zero quote/allocated sizes exactly T, coverage exactly `C_v`, and one transfer
slice exactly T. The checked worst Q wave is persistent zero T + eight provisional
color tiles `8T` + one eight-tile transfer/readback slice `8T` = 8.5 MiB plus at
most 0.5 MiB quoted alignment/cleanup, never above Q=9 MiB. Use W's unpublished
placement-heap phase to instantiate one probe of every frozen descriptor and
verify actual `allocatedSize` before qualified publication, then inspect all
already-live document/Task4 textures against the same device/descriptor receipt.
Future qualified `PaintTileStore` allocations must match that receipt exactly.
Any quote, probe, live resource, descriptor mutation, actual size, or Q-sum
mismatch omits tiled/direct capability atomically and keeps legacy; never shrink
the 512 MiB pools or page counts. Lock equality, alignment/+1, oversized fake-
device, descriptor-usage mutation, and causal physical-high-water tests.

A cold direct-source lease prevalidates each complete exact Task 8 child-batch
entitlement under the store lock, then pages in and pins at most eight backed
references per transfer wave, discarding each backing only after its resident
install. It exposes that child lease only after every wave succeeds, rolls back
every accumulated pin on failure, and records the causal physical high-water at
each wave. Tier 2 remains <=512 textures and fallback <=16; a radial D is never
one monolithic 848-texture submission. No partial lease or root/submission
mutation may escape.

For a 4096² nonradial document, `N_F = 256`, and the scoped document + Task 4 +
shared presentation tile-store/workspace/metadata envelope `E_tiles` is exactly
`1,372,923,904` bytes (`1309.322265625 MiB`); the 512 MiB document and 512 MiB
Task 4 partitions are unchanged. For the exact maximum accepted 4096² radial
layout, `N_F = 848`, `V <= min(848, 682) = 682`, and `E_tiles` is
`1,993,680,896` bytes (`1901.322265625 MiB`). Checked arithmetic also preserves
the defensive 1,024-page API `E_tiles` ceiling at `2,178,230,272` bytes
(`2077.322265625 MiB`). `E_tiles` excludes the separately reserved `G_m` compact
GPU-host arena and `C_m` CPU-plan builder; tiled/direct capability equations
below add each exactly once. Direct display reuses the visible sparse-plan
controller but replaces independently rounded plan buffers with one fixed
physical arena: a `storageModeShared`, `type=.placement` `MTLHeap` of
`P_gpu=67,108,864` bytes (`64 MiB`) containing one placement-backed 64 MiB parent
buffer. Before heap creation, admission proves `device.maxBufferLength>=64MiB`,
queries `heapBufferSizeAndAlign(length:64MiB, options:)`, requires quoted size
`<=P_gpu` and compatible alignment at offset zero, and reserves P_gpu. Require
`heap.size==P_gpu`, `heap.currentAllocatedSize<=P_gpu`, and the parent created at
offset zero with `parent.heap===arenaHeap`, `heapOffset==0`, and
`allocatedSize<=P_gpu`. No standalone plan buffer is allowed. Heap failure
creates zero children; placement failure destroys the unpublished heap; physical
high-water counts the heap once.

The parent contains exactly 68 nonaliasing fixed slots of `B=655,360` bytes. At
each `slotBase=i*B`, the descriptor subrange is `[0,256)` (three 32-byte
descriptors plus fixed padding), the dense-entry subrange is `[256,131,072)`,
and the backend-exclusive range is `[131,072,655,360)`. Preserve the ABI-v2
bind-once model: each compact content installs one global dense table per role,
binds descriptor and entry offsets once, and changes only the fallback remap
offset per draw.

Qualified admission authenticates compiler-issued canvas/layout identity before
source acquisition or build. Compiler-issued finite/periodic addressing is at
most 16x16 pages (256 entries per role). For radial addressing under either
affine or finite-radial output mapping, canvas axes
are 64...4096, the center lies inside the canvas, sector angle is at most pi, and
the exact maximum table is 46x23 = 1,058 entries per role, attained by a 4096²
corner-centered pi sector. Therefore three descriptors plus three maximum radial
tables occupy `3*32 + 3*1,058*32 = 101,664` bytes and fit the fixed 128 KiB
descriptor/entry region. `N_m=1,024` bounds physical references/identities, not
dense logical entries. A non-compiler layout, a role table with 1,059 entries,
or any combined table beyond 128 KiB rejects before acquisition; a genuine new
geometry may select legacy only during capability admission, while a forged or
mutated table inside an already-qualified root is a typed rejection rather than
a frame-local demotion.

One compact content is exactly one ordered compositing-layer pass. A direct D or
stable-layer pass has one canonical role; an active-layer pass has at most the
canonical/authoritative/prediction role trio. Multi-layer tiled/P composition
streams separate layer contents into the same unpublished target in stack order;
it never fuses two layers into another descriptor trio. `sourceLayerCount==1`
is authenticated before table/source acquisition, and a larger count partitions
before allocation. Thus three descriptors/tables is a literal per-content cap,
not an inference from the current shader's first-role lookup.

The backend region is exactly 524,288 bytes. Fallback uses
`256 draws * 512 global bindings * 4 = 524,288`. For Tier 2, query every admitted
fragment pipeline's argument encoder length/alignment, require
`encodedLength<=524,288`, and require every absolute backend address
`slotBase+131,072` for slots 0...67 to satisfy that alignment; otherwise select
exact fallback or omit direct capability before allocation. All draws in one
content share the exact 512-byte sparse/material/fold upload tuple or stream as
another content. No shader ABI change or per-content/per-draw `MTLBuffer`
exists.

The checked receipt is `B_raw=131,072+524,288=655,360=B`. Slots occupy
`68*B=44,564,480` bytes. The three-slot upload ring is the same parent at offset
44,564,480, length `R_gpu=1,536`, ending at `H_gpu=44,566,016`; it is never a
separate resource. The parent retains `22,542,848` bytes of physical slack.
Equality/+1, all-68 fallback and Tier-2 residency/encoding, every Tier-2 argument
length/alignment and absolute slot offset, the exact 46x23 radial table under
both affine and finite-radial output mappings,
1,058/1,059 admission, finite/periodic 16x16 tables, periodic x/y/both-wrap
seams, bind-once descriptor/entry parity, per-draw fallback offsets,
shared-uniform partitioning, and standalone-allocation rejection are frozen by
tests. Raw `MTLBuffer.length` is never physical accounting.
The authority transactionally counts every block and unique content from
acquire/build through final completion—including available, preflighting,
prepared, in-flight, evicted, and pending-completion owners. Task 6 contents are globally
capped at 68 (64 direct cached + one staged-or-serialized-child + three
detached), while a separate fixed
owner-claim authority admits at most three direct visible claims plus one
serialized qualified P/tiled claim. Reserve a claim before any cache hit,
`beginConsumer`, or build; it spans available/preflighting/prepared/in-flight
ownership and remains occupied by pending completion until retry succeeds. A
fourth direct claim or second child claim rejects before mutation even for the
same cached content and an empty upload ring; no unbounded mailbox dictionary is
allowed outside those four fixed records. A child occupies the staged content
slot, so direct build staging waits/rejects until that child invalidates. Each
claim owns at most one content identity and one binding slice at a time. A frame
with more than 256 draws terminally serializes children: encode one child, wait
for resource return plus successful completion/invalidation, release its
content/source token/binding slice, and only then reuse the claim. A fixed
zero-payload aggregate frame token may persist. The first wave authenticates and
clears a private unpublished frame/P target, subsequent waves use authenticated
`.load`, and only the final successful wave may publish/present. Any wave failure
discards the whole target; a pending or failing child prevents the next child
from acquiring.

Allocator scope is mode-exact. Direct-D cached/staged/detached payloads and the
ring use `P_gpu`. The one serialized qualified P/tiled child uses W's
phase-exclusive 15 MiB plan slice plus one `G_m` content/owner record and the
sole `C_m` builder, invalidates before releasing that slice, and consumes zero
`P_gpu` bytes. Below-capability `.legacyLayered` uses only its preexisting
shipping full-output scratch and source-store token metadata, creates one
ephemeral exact child at a time using the same <=4-page leaf and command-wide
<=4-page/<=8-Task4-ref predicates through the shipping plan path, and invalidates
it immediately. Legacy neither
allocates nor claims `R_m`, `G_m`, `C_m`, or `P_gpu` and remains outside Task 6's
bounded/no-full-scratch guarantee. Task 4 color-only identities, the <=8
transient-ref command/D4 bound, and ACK independence still apply through one
existing Task 4 store token/lease.

Qualified direct/P/tiled paths use a compact GPU-content variant rather than the current heap-backed
`allTextures`, key-signature, draw, and per-draw texture arrays. Bind a unique
`rootScopeGeneration` into every key, store only non-owning 16-byte texture-
identity signatures, resolve fallback textures from the owner claim's already-
charged fixed binding buffer, and let an embedded source-retention token own the
actual source liability. One Task 6 GPU content has at most 256 draw batches;
larger output is recursively partitioned/streamed into independently validated
children and no partial frame is published. Each compact content uses fixed
arena slices: `512*16` signature bytes, `256*64` draw-record bytes,
`256*16*2` compact-slot bytes, and a 256-byte content/token header. Four 256-byte
owner records plus 65,536 bytes of allocator/alignment state give
`G_raw = 68*(8,192+16,384+8,192+256) + 4*256 + 65,536 = 2,312,192`;
round to 256 KiB alignment for `G_m=2,359,296` bytes (`2.25 MiB`). Layout,
capacity, equality, and +1 rejection are frozen by tests; Task 6 GPU metadata
may not allocate outside this arena. Each root's fixed <=64 derived-content
identity buffer remains charged to `R_m`'s root/provider allowance. That is 64
total contents for the root scope across cached, staged, detached, in-flight,
and pending states, not 64 cached plus extras: reserve the root ID before staging
and evict an unowned content or reject before a 65th can exist. The global 68
may be reached only across distinct root scopes. Invalidation scans the root's
fixed IDs and the fixed 68 headers by `rootScopeGeneration`; neither path
allocates.

Task 6 qualified direct/P/tiled presentation bypasses retained
`SparseTileSamplingPlanCache.contents` entirely. On a GPU-cache miss, one
`CanvasPresentationSparsePlanBuilder` reserves the sole `C_m` arena before any
source capture, `beginContentAcquisition`, or heap build. Every qualified direct/P/tiled
mapping and source role—affine, periodic, and finite-radial;
canonical D, stable layers, and active canonical/auth/prediction—recursively
partitions with its mapping-appropriate exact authority until each leaf's
physical-page set is <=4. A one-pixel leaf terminates at its four bilinear
neighbors. Before build, partition again until both `drawCount<=256` and aggregate
unique role-qualified `bindingCount<=512`; disjoint page sets may hit the latter
first. If a content samples either Task 4 role, partition more strictly at the
*command* boundary until the mapping physical-page union across every draw is
<=4 and the exact authoritative+prediction reference union is <=8. This
command-wide predicate, not the per-leaf predicate, owns D4; canonical-only D
and stable-only contents may still use the 512-binding cap. Bind the authenticated
aggregate page-set identity and exact bitset into child selection, restricted
lease, compact content key, and final page/slot validation. This universal exact
<=4-page leaf rule bounds physical selection and bindings, not the dense ABI-v2
table area. Preserve one bind-once global dense table per role. The same
authenticated compiler-layout gate caps each role at 1,058 entries and the
combined descriptors/tables at the fixed 131,072-byte region; finite and
periodic tables are at most 256 entries per role. Its packed layout is:
`256*64` draw records + 131,072 combined role descriptors/page entries +
`512*128` binding records + `256*16*2` remaps + `4,096*32` hash/dedupe slots +
`512*32` source fingerprints + 4,096 header + `4,096*16` sorting scratch +
65,536 allocator/alignment = `C_raw=503,808`;
round to `C_m=524,288` bytes (`0.5 MiB`). Layout/equality/+1 are frozen, only
one builder may own the arena, and no Swift Array/Set/Dictionary allocation is
permitted in this path. A hit needs no CPU build. A miss emits the compact GPU
content, then releases the CPU arena immediately; no Task 6 CPU plan content is
cached or retained. Cache lookup may use digests only as accelerators. The fixed
content header retains and compares the complete authenticated value tuple:
root-scope generation, exact child region/output geometry, full mapping and
addressing identities, reachability-claim identity plus exact page set, source
revision/identity tuple, and pipeline/backend. Root-minted monotonic identities
are non-ABA and stable only for the intended exact cache reuse; digest equality
without full tuple equality is always a miss. Recycled arena `ObjectIdentifier`
values are forbidden.

The 256-draw limit is per compact content, never a per-frame rendering cutoff.
Every qualified result—including canonical-only direct D, projected P, and every
tiled stable/active-layer pass—uses one fixed 64-byte stream cursor in `R_m` and
emits as many terminally settled compact children as its finite exact partition
requires. `R_m` contains exactly four such records—one for each of the three
direct owner claims and one for the serialized qualified child—and rejects a
fifth before preparation; no per-result heap cursor exists. The cursor stores
only checked `UInt64` layer/pixel progress, current
descriptor position, serialized-command count, and rolling authenticated
partition digest; it owns no child array. Define the monotone work measure as
the immutable set of `(visibleLayer, outputPixel)` pairs. Descriptor-overflow
bisection strictly reduces a nonempty region until one pixel, and each successful
terminal child consumes at least one previously unconsumed pair. With
`LayerStack.maximumLayerCount == 8`, both covered work and command count are
therefore bounded by `checked(outputPixelCount * 8) <= UInt64.max`; zero progress,
overflow, duplicate coverage, or a count beyond that proof is a typed
prepublication planner failure. A failed/pending terminal does not advance the
cursor or start another child, and revision change discards the aggregate result
instead of treating a retry as progress.

P/tiled children hold the single qualified child claim through command terminal;
direct D may use its at-most-three direct claims, but the receipt counts every
child across all claims, layers, and contents. Only the fixed cursor, aggregate
unpublished-target token, and current child claim persist. First child clears the
private target, later children load, and only the final child may publish/present.
The 3024x1964 rectangular and finite-radial maximum-role acceptance fixtures must
each record `serializedChildCommandCount <= 256` for direct and tiled paths and
meet the Task 10 end-to-end latency budget. A synthetic 257-child result must
remain exact and bounded—child 257 starts only after child 256 terminal, uses the
same fixed cursor/arenas, and publishes no partial output—proving 256 is a named-
fixture performance ceiling rather than a data-dependent full-scratch fallback.

Qualified Task 6 source acquisition likewise writes at most 512 bindings directly into
the owner claim's one fixed `R_m` binding buffer. It does not construct the
heap-backed `PaintTileLease.ownedBindings`,
`TiledRasterExactReferenceLease.bindings`, or
`SparseTileSamplingPlanLease.boundTextures` arrays. The store's exact pin token
references that fixed slice; rollback or final completion clears it in place.
Cache eviction does not release bytes
until the final strong plan/completion owner settles. Candidate capacity is
reserved before the first Metal allocation and released on every failure. The
64-slot steady compact cache occupies exactly `64*B=41,943,040` bytes inside the
68-slot physical arena; it is never misreported as the peak. Exact direct
capability thresholds are
`1,442,916,352` bytes (`1376.072265625 MiB`) rectangular,
`2,063,673,344` bytes (`1968.072265625 MiB`) radial-848, and
`2,248,222,720` bytes (`2144.072265625 MiB`) at the hard 1,024-page ceiling.
Tiled-exact without a presentation store is
`512 MiB + 512 MiB + 16 MiB + R_m + G_m + C_m = 1,095,761,920` bytes
(`1045 MiB`); it owns zero
presentation-store references. Startup below that tile-workspace capability
uses an explicitly named `.legacyLayered` root rather than failing or shrinking
either 512 MiB pool; the Task 6 no-full-scratch guarantee does not apply to this
below-capability preservation mode. Partial Task 5 capacities are not
direct-display capacities:
direct mode receives the full geometry-specific store/metadata partition or is
omitted. An unknown working-set recommendation starts legacy and may promote to
tiled/direct only after a transactional allocation probe reserves the exact
workspace/metadata (and full geometry store for direct); threshold-minus-one
remains in the lower capability. Direct admission transactionally preallocates
the complete single-parent `P_gpu` arena; exact placement heap/parent identity
admits, and the first fixed slot or aligned subrange exceeding it rejects without
changing cache/submission state. Reuse the existing visible-plan controller and never
create a second physical arena. Tiled startup/steady state closes or does not
instantiate that global arena and uses only W's 15 MiB GPU-plan
subprofile. A direct→tiled transition may release `P_gpu` only after every old D
GPU plan/root drains; tiled→direct admits it before publishing the first D.

`P_gpu` accounts direct Metal plan/upload buffers, not source textures. Before a
direct content's temporary owner binding slice clears, its encoded physical IDs
are registered in one fixed root-owned aggregate residency/external-resource pin
token. That token reuses the root's D reference/bitset storage plus one internal
metadata ticket, deduplicates identities, and forbids backing, replacement,
release, or rebind of those store records until every derived content is
invalidated and the root retires. It may conservatively retain the union of all
IDs used by the immutable root; the store already counts that exact unique union
across current and retiring roots within `2N_F`. A cache hit validates the same
physical identity/version, resolves the still-pinned record into the owner's
fixed binding slice, and issues `useResource`, so neither a stale argument handle
nor a duplicate resident texture can escape accounting. Every qualified Task 6
GPU plan content also has a noncopyable source-retention token that keeps
every texture reachable through its argument/remap encoding charged to its
originating document, Task 4, or presentation store/root; the compact content
itself owns no duplicate strong texture array. Its `rootScopeGeneration` forbids
a cache hit from transferring an old root's token to a metadata successor, even
when CPU content and texture identities match. Direct contents may remain cached only while
their owning D root retains that liability; tiled/P child content is invalidated
at terminal before its exact source lease is released, and legacy applies the
same ordering in its ephemeral shipping owner. Root
retirement first closes future preparation, waits the root's resource-return and
terminal latches (including completion-mailbox retry), invalidates every GPU
content derived from that root, verifies no external content owner remains, and
only then closes D/source capture liability. Thus cache eviction, invalidation,
and strong `MTLTexture` lifetime can never move tile payload outside `2N_F`,
`D_4`, or the unchanged source-store partition. Invalidation failure/backpressure
keeps the root/source token counted and non-idle; it never releases accounting
early.

Tiled roots hold only frozen stable/Task4 provider-reference metadata and an
invalidation fence; they allocate no presentation-store pixels and own no
full-set source token. Bound retiring
roots to current plus three in-flight/retiring D slots and one nonborrowable
successor slot acquired before any Task 4 publication/ACK. The sparse pipeline
allows at most three direct claims plus one serialized child. Every cached,
staged, detached, or pending GPU content/source token also counts as a borrow of
its root. Successor preflight computes the post-swap root set and permits at most
three retiring roots; a current root with the child claim plus three retirees
backpressures before mutation. For source-dependent tiled/legacy target-root
transactions only, the coordinator may close the base root's preparation gate
and await allocationless invalidation of derived content with no external owner
before Context; this never waits for a GPU command, and a prepublication failure
reopens the unchanged base gate. A direct/hybrid transaction never performs this
purge: it reserves the retiree/successor slot and keeps the exact old D gate and
contents drawable through any post-Context retry debt. Any remaining content
makes its root a retiree. Only a root with zero display
borrows, zero owner claims, and zero derived contents closes synchronously at
swap and replenishes the successor slot. If the retiring set is full, successor
admission backpressures before document or Task 4 mutation; committed publication
never discovers the shortage. Tiled/legacy target preparation, Context, or claim
failure before the nonthrowing swap reopens the unchanged base root's gate; its
intact sources may build fresh content and redraw normally.
In qualified direct/tiled modes, `R_m` reserves 2 MiB for nine copy-on-write-shared `N_m` reference buffers, four `N_m` binding buffers, fixed
1024-bit presence/claim bitsets, and root/provider/lock overhead, plus a rounded
67,904-byte internal store reserve (eight tokens and 8,192 tile IDs).
The fixed records contain exactly 32 noncopyable inline
`SIMD16<UInt64>` payloads: ten for five root D-presence/reachability pairs, four
for at most two P publications' presence/nonclear pairs, four for simultaneous
owner/child selections, four for root pin/retirement unions, four for promotion/
debt claims, two builder-union scratch values, and four transaction scratch
values. Moves transfer one record and borrows create no payload; copying is a
compile-time error, persistent values live only in the charged root/claim/
provider records, and a 33rd payload rejects before mutation. Lock the word
payload at128 bytes and the complete value stride at160 bytes; the resulting
`32*(160-128)=1,024` header/alignment bytes are included in the fixed 65,536-byte
root/provider/lock term rather than charged twice.

A `CanvasProjectedPreviewSnapshot` borrows its immutable P publication's pair
and owns no bitset copy. At most two P metadata publications may coexist:
current+candidate or current+one externally retained retiring publication. If a
retiring external snapshot and current P already occupy both pairs, another P
candidate backpressures before allocation; publication linearization never
creates a third pair.

The authority mints a process-global monotonic non-ABA domain identity; counter
overflow rejects before minting. No coordinate table is allocated: finite and
periodic addressing use page-geometry row-major index, while radial addressing
uses the compiler-issued compact resident `atlasSlot`. The full immutable
geometry tuple and indexing rule live in the existing root/provider fixed record.
A digest is only an accelerator. Exact domain identity, bitCount, and tail mask
are revalidated on every operation; iteration is `index < bitCount`; a set bit
at index848 for bitCount848, index682 for bitCount682, or any other first out-of-
domain index rejects before publication.
Preserve Task 5's external 256-token/262,144-ID entitlement; qualified direct/P/tiled
internal captures use only the added reserve through a single `CanvasPresentationMetadataAuthority`
shared across the presentation, document, and Task 4 stores. A source-store
child capture transactionally consumes/releases a ticket from this authority;
no PaintTileStore receives an independent extra reserve. If all internal tickets
are in the presentation store, its exact maxima are 264 active tokens, 270,336
aggregate retained IDs, and 2,240,832 metadata bytes. External requests cannot
consume the eight/8,192 internal reserve. The simultaneous qualified equation is
phase-exclusive and exact: successor publication is at most five D root tickets
+ current F + current P + one candidate/debt = eight; ordinary preparation is
at most four D roots + F + P + one temporary cross-store child-capture ticket.
Each slot is capped at `N_m=1,024`, so retained-ID high-water is <=8,192. The
temporary ticket validates/acquires document and Task4 stores sequentially and
returns as soon as their fixed lease/pin records are installed. The three direct
owner claims are sub-borrows of their root aggregate pin and consume zero extra
token/retained-ID tickets; successor publication and child acquisition are
mutually exclusive. Below-capability legacy instead uses
one existing shipping capture/token entitlement (including stable and Task4
sources) and releases it with each terminally serialized ephemeral child; it
never touches the added authority. Lock `PaintTileReference == 144` bytes and
`PaintTileBinding == 96` bytes with layout tests. Admit five total root slots:
at most four borrowable/live-binding roots plus one nonborrowable successor;
reject a sixth total root or fifth borrowable root before metadata allocation.
The checked fixed heap equation is
`9*N_m*144 + 4*N_m*96 + 32*ceil(N_m/64)*8 + 65,536 = 1,789,952` bytes;
round its 2 MiB subpartition plus 67,904 bytes to 256 KiB alignment to obtain
`R_m=2,359,296`. Legacy applies the same logical root/retirement limits using its
preexisting shipping records rather than this partition.
Task 4's presentation store becomes a color-only, physical-versioned store while
preserving its public 682 combined-role limit and 512 MiB partition. This is not
a semantic loss: its current copy path clears every component-coverage texture,
marks the surfaces presentation-only, and `PaintTileBinding` exposes color only.
Never replace a texture under one `PaintTileIdentity`; every modified coordinate
gets a new physical identity/generation, unchanged refs carry, and clears/
removals are metadata absence.

Reserve `D_4 = 8*T = 4 MiB` *inside* the unchanged Task 4 partition for
lease-pinned retired color versions. Every Task 4 presentation consumer—P,
tiled-exact, and below-threshold legacy—uses the mapping-appropriate exact child
authority (the new GPU authority for finite-radial; the already-proven Task 8
authority for affine/periodic) and recursively bisects until shader-neighbor
reachability has <=4 physical pages and therefore <=8 Task 4 color refs
and the global presentation+document+Task4 internal authority can admit the
child without exceeding 8,192 live IDs.
For each child it atomically creates a restricted capture, borrows, leases those
refs, then closes the borrow and capture before encoding; only the lease survives
to command terminal. The resulting GPU plan content carries a one-shot source-
retention token. At terminal/resource return, invalidate that exact GPU content
before releasing the source lease; a fallible plan-completion mailbox retains
both the token and lease as counted Task 4/document debt until retry succeeds.
Cached child content may never outlive its <=8 Task 4 liability. A root retains
frozen provider/reference metadata plus an
invalidation fence, never a full-set Task 4 token. One Task 4 child command at a
time participates in the allocationless command-terminal arbiter; qualified
P/tiled children use W, while legacy may retain its full-output scratch but
cannot retain a wider raw transient lease.

When Task 4 advances, gate future old-version acquisitions, cancel/discard the
unfinished tiled frame or P candidate, and prepare the exact successor metadata
root without making it borrowable. In tiled/legacy mode, one closed-gate,
nonthrowing linearization swaps the Task 4 role view and publishes/arms that
successor root before retirement and ACK; preparation failure rolls the
candidate back. In direct mode, old D is independent and stays current while new
Task 4 refs publish/ACK and await P, so no raw-source root swap is required. ACK
never waits for the sole old command. Its <=8 old colors remain counted in
`D_4`; no newer Task 4 child starts until that lease terminal, so debt cannot
stack. A maximal 682-tile current revision uses only
341 MiB of color plus zero/debt. More generally every update admitted by the old
color+coverage accounting remains admitted: when current+candidate count is at
least 16, removed half-tile coverage is >=`D_4`; below 16, the full bound is far
below 512 MiB (exact worst 19.5 MiB). Precisely, let `C_v=T/2`, N be current entries, A newly reserved
color entries, K replacement candidates, `0 <= A <= K`, `Z∈{0,T}`, and
`D≤8T`. If
`P_old=N(T+C_v)+A*T+K(T+C_v)+Z≤512MiB`, then color-only
`P_new=N*T+A*T+K*T+Z+D`; for `N+K≥16`, `(N+K)C_v≥8T`, so
`P_new≤P_old`, while the finite `N+K<16` branch is checked directly. Lock this
implication with exhaustive boundary arithmetic tests and reject `A > K`
before allocation.

The version transaction is failure-atomic. Before encoding, reserve every new
physical ID/color, packed successor ref buffer, token/metadata/root slot, exact
union admission, and replaced-ref retirement; clear/removal reserves no texture.
GPU-copy candidates remain unpublished. Allocation, encode, GPU, stale-fence,
or CAS failure closes candidates/prepared retirement and leaves current refs/root
unchanged. After GPU success, take one store/coordinator lock, close the old
acquisition gate, revalidate revision/CAS, then perform a nonthrowing reference-
view/root publication and request old-ref retirement. No rollback-requiring seam
is permitted after the first identity swap; ACK follows that atomic publication
without waiting for old lease terminal.

The Task 4 store exposes no raw `current()` provider/capture. Its actor-confined
child API revalidates expected revision and exact refs, enforces one internal
capture token/at most eight refs/`maximumPayloadDebtBytes=8*T`, creates the
restricted capture and lease synchronously, closes borrow+capture, and returns
only the lease/bindings plus a revocable output-publication token. The global
metadata ticket is released with capture close. Adoption revokes older output
tokens but never force-closes an in-flight lease.

Task 4 source publication must not sit behind W's held presentation command on
the same serial `MTLCommandQueue`: use a dedicated synchronized Task 4 copy queue
(the handed-off source work is already GPU-complete), or an equivalently tested
independent scheduling fence. The allocationless presentation-command arbiter
serializes P/tiled/legacy transient children, and only qualified P/tiled work
owns W. Current, candidate, and lease-pinned retired Task 4 color records stay
resident; disable raw-provider memory-pressure backing for this store and admit
every version change against the resident physical union. A child therefore
never cold-faults a Task 4 presentation ref, and its <=8-ref retired-version
debt is the complete escape liability rather than resident plus backing plus
staging.

If a candidate P would exceed the shared physical union, first prepare and
publish an exact whole-frame tiled root for the same Task 4/mapping revision. If
that publication fails, keep the old direct D/P untouched. After tiled
publication, reject new direct preparations and wait every retired D root that
contains the old P revision—including publisher ownership, D borrows, resource
return, and terminal callbacks—then drop/retire old P and rebuild the latest
exact P in freed slots. Any allocation/compositor/capture/stale/CAS failure leaves
tiled-exact current; success atomically publishes a new D. Task 4 ACK remains
independent of this drain.

Geometry/storage changes first publish an exact tiled root when tiled capability
is admitted, otherwise a legacy root, then close the old core's snapshot/source-
acquisition gate and retire its publisher ownership. Drain *every* old-core owner,
not only direct roots: external Task 5 F snapshots and sparse borrows, projected
snapshots, child leases, candidates/prepared retirements, cleanup debt, cached/
staged/pending GPU contents, and aggregate residency/source tokens. Require old-
core token/ref/payload/physical bytes and owner diagnostics exactly zero before
destroying its store or allocating the new exact envelope and full-bootstrap.
A held external F/P snapshot, child lease, or GPU-content owner therefore
backpressures the geometry transaction without invalidation and can never keep
the old heap alive beside the new one. Lock held-owner cases and exact zero-before-
first-new-allocation receipts. Old/new presentation stores may never overlap.

The renderer starts in whole-frame tiled-exact mode when that exact capability
is admitted, otherwise in explicit legacy-layered startup mode. It publishes
`.directProjected` only after the full mode/geometry-specific envelope is
admitted and a latest-identity F bootstrap succeeds. Cache absence, low/unknown
memory, union pressure, or a stale/missing reachable P coordinate selects one
atomic `.tiledExact` root for the entire frame when tiled capability is admitted,
otherwise the explicit legacy root; never mix per-tile fallback with F.
Tiled-exact rendering recomposites the real frozen stack through the
shared tile kernel into <=256² output regions with <=16 MiB workspace and zero
full-drawable scratch. It is not raw transient-over-F. Direct mode may be
re-entered after a fresh exact bootstrap/P publication.

Qualified tiled/direct tests must prove neither mode dispatches legacy. The
legacy case exists only to preserve the preexisting startup contract below the
minimum bounded-tile workspace threshold and is never described as satisfying
the direct/tiled no-scratch acceptance criteria.

For each direct root, the shared core constructs one immutable display reference
view `D` in the existing canonical role:

```text
D = F references whose coordinate is not in P.explicitPresence
  ∪ P nontransparent references
```

An explicitly clear P coordinate contributes no D reference, so it suppresses
an opaque F tile and samples transparent; an absent P coordinate carries F.
Require P nontransparent and transparent coordinate sets to be disjoint and to
partition explicit presence. F, P, and D share one store/layer/pixel descriptor
but use distinct physical surface namespaces. `D` owns one exact mixed-namespace
capture and contains at most one reference per coordinate. Existing Task 8
canonical-role lookup and per-neighbor bilinear sampling therefore implement
replacement with ABI v2 unchanged—no projected shader role, presence wire bit,
or second provider is allowed. Shader roles/layout stay byte-for-byte v2; the
only shader-source change is the mapping-only radial child entry point and the
shared precise address helper used by it and existing radial sampling.

Recompute/authenticate the same reachability claim before D creation and draw
preparation. Every reachable live coordinate must be explicitly represented by
P before D is minted; otherwise the whole frame is tiled-exact. The root owns D,
while F/P publication metadata remains in the shared core for promotion and
retirement. D creation/capture must precede retirement of any removed F/P ref.

The presentation root is the sole identity/currentness authority during draw
preparation. The draw path must not re-read Context identity after acquiring a
root. A direct root owns exactly one immutable merged D snapshot/capture; F/P
publication metadata remains actor-confined in the shared store core. A
tiled-exact root owns one frozen layer/source plan and no presentation-store
reference. Publication releases only publisher ownership; superseded roots
close after the last preparation/submission borrow settles. Shutdown/deinit
rejects new borrows, retires publisher ownership, and drains every borrow before
cache shutdown. Closing one borrow can never close another root alias.

Every source-dependent tiled-exact or legacy canonical successor is prepared as
a nonborrowable *target* root before Context publication, not reconstructed
after the document transaction. SurfaceStore prepares its target provider/
reference metadata and invalidation fence alongside the application and returns
a one-shot `CanonicalPresentationPublicationClaim` that owns the replaced-source
retirement liability. All allocation, capture, plan construction, and validation
must finish before Context may linearize. Once Context publishes, one closed-gate
coordinator critical section performs no await and no throwing operation: it
closes the base root's future child-acquisition gate, installs/arms the target
root, completes the claim, and requests the deferred old-source retirement.
Already acquired base-root child leases remain counted and readable through
command terminal; the target metadata refers only to the installed target
records. Preparation or Context failure leaves the base root and source records
unchanged. This protocol applies to stroke and every non-stroke canonical
mutation. A direct D is independently retained and therefore may remain the
visible retry root while its F successor is repaired, but a tiled/legacy
post-Context retry always retains the already-published *target* root, never the
base root whose sources the document transaction replaced. A pre-Context
direct-to-tiled capacity transition first publishes its exact base tiled root,
then separately prepares the target tiled root for this same claim.

Display submissions own one root borrow plus sampling/GPU leases and never own a
scheduler acknowledgement. Nil drawable, stale revision, cancellation, encode failure,
command failure, and completion settle leases exactly once and never gate Task 4
ACK/cache progress.

- [ ] **Step 1: Write semantic, cutover, and ownership REDs**

Before production changes, prove the old architecture fails:

1. a lower-layer stroke must remain occluded by opaque stable upper content;
2. a top-layer erase must reveal the stable lower layer;
3. active opacity plus normal/multiply/screen must match a tile-level
   `LayerCompositor` oracle;
4. a transparent projected tile must replace nontransparent canonical content;
5. one D view must merge distinct F/P physical namespaces under the shared
   presentation layer ID, reject a mismatched layer ID, and carry at most one
   reference per coordinate;
6. gated commit/application must expose only the old merged D (old F plus P
   replacement) and then the new-F D, never an intermediate mixed root;
7. post-document-publication failure with a genuine pre-reserved F/direct claim
   must retain an exact drawable root and non-idle debt: either old direct D plus
   exact F/P debt for an independently retained direct source, or the already-
   installed target tiled root plus that exact F/direct claim. The replaced base
   tiled root is never the retry source. Force both variants, inject F/current/D
   failure after Context, repeatedly render the retained root, and prove the
   exact claim fences later canonical mutation until retry settles. Separately,
   force permanently tiled-only and legacy modes with no admitted F/direct claim,
   replace every referenced stable tile, and prove the nonthrowing target-root
   arm is the mutation's terminal success: the target remains repeatedly
   drawable while an already-leased base child reads base bytes through terminal,
   the operation becomes idle, a later canonical mutation is admitted, and a
   failed optional direct bootstrap creates no debt. In every variant require no
   await/throw seam between Context and target-root arm, unchanged 512 MiB source
   bounds, and retirement returning to zero after the final old lease;
8. no-op commit must drop `P` atomically;
9. stale identity and every terminal path must settle all borrows exactly once;
10. nil drawable must not block cache/ACK progress;
11. empty/nonempty bootstrap plus import, restore, clear, resize, layer-stack,
    history, and archive mutations must publish exact canonical successors;
12. a canonical mutation attempted while a genuine pre-reserved F/direct claim
    remains in post-publication debt must stay fenced until that exact claim
    settles; tiled-only/legacy target-root completion with no such claim must not
    create a fence or delay the next mutation;
13. prediction replacement/clear and incremental dirty updates must reproject
    only current exact coordinates rather than cumulative prior dirties;
14. shutdown/deinit and preview pressure/closed-cap failure must preserve or
    report debt and settle every root/capture/candidate exactly once;
15. a candidate whose exact physical union equals the store cap must publish
    direct; one additional tile, cache absence, and stale/missing reachability
    must atomically publish whole-frame tiled-exact with old D/P intact until the
    tiled root exists;
16. D must exclude F at every present P coordinate, including explicit clear,
    and old/candidate/retiring root physical union must stay under `2N_F`;
17. authenticated final P refs must be physically identical in new F, remain
    valid through overlapping old-P/new-F captures, and never be retired by P
    cleanup; full-composition bytes must match the hybrid result;
18. rectangular/radial envelope equations, threshold-minus-one/exact/unknown
    device policy, 848-page radial geometry, and 682 Task 4 entries must be
    literal. Before any qualified store, lock physical tile descriptor quotes and
    probes at color/zero T, coverage `T/2`, transfer T, and Q's exact 8.5 MiB+
    0.5 MiB boundary; one-byte/alignment/usage/actual-size mismatch must remain
    legacy without reducing either source pool. Lock `B_raw=B=655,360`, 68 slot
    bytes at `44,564,480`, `R_gpu=1,536`, `H_gpu=44,566,016`, and
    `P_gpu=67,108,864`. Prove physical closure with one placement heap and one
    64 MiB parent: max-buffer-length/size-and-align preflight, exact heap/parent/
    offset identity, all 68 fixed slots plus the in-parent ring, all internal
    padding, heap/placement failure with zero published children, and rejection
    of the first out-of-arena resource. Exercise all-68 fallback and Tier-2
    occupancy, every queried argument length/alignment at all absolute slot
    offsets, and prove tiled owns zero parent buffers while transitions count/
    drain the arena exactly. Mode snapshots must show direct-D content only in
    the parent, a qualified P/tiled
    child only in W with zero `P_gpu` delta, and legacy using none of
    `R_m/G_m/C_m/P_gpu`.
    Lock `G_raw=2,312,192`/`G_m=2,359,296`, fill all compact slices, partition the
    257th draw out of one compact content, reject a 69th simultaneously live
    global content and a 65th content in one root scope
    before mutation; different roots may reach 68. Lock
    `C_raw=503,808`/`C_m=524,288`, fill/reuse the sole CPU builder at equality,
    reject +1 before source capture/acquisition/build, and prove more than the
    retained-cache cap of distinct output regions/root generations leaves zero
    Task 6 CPU cached/active/retirement bytes. Source/build/completion failures
    must release the CPU arena, fixed 512-binding slice, and every pin; 513
    disjoint role-qualified bindings rejects at 513/partitions to another child,
    and no forbidden heap-backed binding array is created in a qualified path.
    Rectangular `N_F=256` and tiled-only fixtures must still fill the fixed
    `N_m=1,024` owner slice to binding512 and reject/partition binding513.
    Fill the four fixed 64-byte stream cursors with three direct results plus one
    serialized qualified child and reject a fifth before target/source work.
    Fill the two phase-exclusive token equations at eight/8,192 (five roots+
    F/P/candidate and four roots+F/P+temporary child), reject +1 before capture,
    and prove three direct owner claims add no token/ID entry while their pins
    remain counted.
    Fill all 32 fixed domain-bit records, move/borrow/compare/iterate them with
    zero heap/arena delta, prove copying is unavailable, and reject record33
    before mutation. Lock each payload at128 bytes and full stride at160; prove
    all 1,024 header/alignment bytes remain inside the fixed 65,536 term. Test
    bit847/848 for N=848,
    bit681/682 for N=682, and
    0/64/1,024 boundaries with forged tail-bit rejection. A deliberate digest
    collision and finite/periodic row-major versus radial-atlasSlot probes must
    still compare
    the exact authority identity/indexing rule, never alias two domains, and never emit
    a phantom coordinate. Five simultaneously live root domains fit their fixed
    records and a sixth root rejects under the existing root cap. Hold an
    external P snapshot across publication: it borrows rather than copies its
    payload, a second P publication fits, and a third candidate backpressures
    before allocation until the old snapshot closes. After closing a P snapshot
    or root borrow, its borrow accessor must typed-reject without trapping or
    exposing storage.
    Deliberate key-digest collision must miss after full-value comparison.
    Affine/periodic/radial one-pixel leaves must terminate at <=4 physical pages.
    Lock compiler-issued finite/periodic tables at <=16x16 entries/role and the
    exact 4096² corner-centered pi-sector radial table at 46x23=1,058/role under
    both affine and finite-radial output mappings;
    1,059 or a combined table beyond 128 KiB rejects before acquisition. Periodic
    4096² x-wrap, y-wrap, and both-wrap pixels, radial maximum, and fallback/
    Tier-2 pixels must preserve bind-once descriptor/entry parity. One source
    layer per compact content admits; a second layer partitions before table or
    source acquisition, while eight-layer tiled output streams ordered passes
    and matches the full-stack oracle.
    Task4-sampling command with two disjoint four-page leaves must split before
    acquisition; command-wide four-page/eight-ref equality admits, while a fifth
    page or ninth Task4 ref partitions/rejects without increasing D4. An old
    version adopted between those serialized commands discards the whole result,
    and canonical-only direct content still admits its independent 512-binding
    boundary. A >256-draw frame must execute clear/load/final-present children
    whose second child cannot acquire while the first is terminal/pending and
    whose failure publishes no partial frame. A synthetic 257-child result must
    use the same fixed cursor/arena high-water, end with exact bytes, and never
    demote qualified mode; each 3024x1964 maximum-role rectangular/radial direct
    and tiled fixture must count every layer/content child, record <=256 total
    serialized commands, and meet the Task 10 end-to-end latency budget. Repeated
    D-root and tiled/legacy/P-child
    revisions must prove every GPU content's source textures remain charged to
    the exact root until invalidation. Clear a direct owner's temporary binding
    slice, force presentation-store pressure/backing, and prove cached identities
    remain resident, pinned, version-identical, and pixel-exact; invalidate and
    retire the root, then prove the pin union reaches zero and backing becomes
    legal. Cached-only contents count as root borrows:
    pause invalidation across a swap and prove no root/source/successor slot is
    reused; six zero-command revisions remain within five root slots. Three
    failed completions on one cache-hit content retain the three fixed direct
    owner claims after upload return, the fourth rejects before `beginConsumer`,
    retry reaches zero, and a second serialized child rejects. Current-child
    plus three retirees must backpressure before mutation. Metadata-only roots
    with identical content/textures use distinct scope keys, and old invalidation
    leaves successor content untouched;
19. tiled overflow must drain every P-bearing D metadata/root/lease and both GPU
    terminal latches before P slots are reusable, coalesce to the latest Task 4
    and mapping revision, and leave tiled mode current on every rebuild failure;
20. hybrid overflow must switch/drain before Context publication, then use normal
    full canonical composition within `2N_F`; and
21. cold all-backed D acquisition at the maximum admitted `N_F` must prevalidate
    once, transfer/pin in waves of at most eight, stay under Q at every causal
    observation, expose no partial lease on injected failure, and settle all
    pins exactly once;
22. an all-clear P batch at the physical cap must admit each provisional
    destination before reduction, release every reduced-clear destination, and
    retain only authenticated explicit-clear metadata;
23. a provisional candidate at the exact cap that reduces nonclear must not
    convert Q staging into durable payload: it rolls back completely and enters
    the tiled/legacy capacity transition before publication;
24. tiled roots must own zero presentation-store refs/full-set Task 4 token;
    every Task 4 child uses a restricted <=8-ref capture that closes immediately
    after leasing, old/new refs use distinct physical identities, and at most
    `D_4=4 MiB` of lease-pinned retired color survives while ACK proceeds without
    a display-terminal wait;
25. geometry resize must publish tiled/legacy, gate old acquisition, and drain
    every old-core owner. Held Task5 F/P snapshots and borrows, child leases,
    pending GPU content, and cleanup each block first-new-allocation until old
    physical/token/ref diagnostics are exactly zero; only then destroy/bootstrap
    the new exact store without overlapping mode-specific envelopes; and
26. Task 4 color-only storage must admit the same exact old-state/update domain
    as the prior color+coverage equation at cap/+1 and current+candidate 15/16,
    reject `A=K+1`, preserve the 682 limit, and allocate zero coverage bytes;
27. an eight-ref old child followed by repeated replacements must ACK before the
    held child terminal, keep old/new texels under distinct identities, reject
    stale reacquisition, and never accumulate more than eight retired versions.
    In direct mode, N→N+1 must publish only the role view/ACK eligibility while
    old D/root revision/GPU scope remain unchanged until P N+1 publishes; tiled/
    legacy must atomically arm the prepared rooted successor with the role view;
28. a ninth reachable Task 4 color must deterministically bisect the child while
    preserving periodic/radial seam output against the monolithic oracle; the
    generic radial 3x3 authority must reproduce its >16-role-ref one-pixel RED,
    while the shared-precise GPU child authority must yield at most four
    physical pages, eight Task 4 refs, and 12 total active-layer bindings at
    ray/page/center/corner seams on both sparse backends; a dense canonical-only
    D and a stable-only tiled fixture must each reproduce broad-radial fallback
    failure and exact-authority success with <=4 bindings; an
    aggregate 8,192-ID child must admit while 8,193 bisects, and an update
    between children must discard the incomplete frame/P; and
29. a below-threshold legacy frame at the 682-role bound must use the same <=8
    Task 4 child discipline and let N+1 ACK while its old command is held, with
    retired-version debt never exceeding D4;
30. a 3024×1964 direct frame and a forced tiled-exact frame must enter no
    full-output `LayerCompositor`
    display path and allocate zero full-drawable scratch; and
31. mixed document+Task4+presentation child captures must share one global
    eight-token/8,192-ID internal metadata authority, hit exact/equal/+1
    admission boundaries, and return aggregate high-water to zero without any
    store independently minting the reserve; and
32. with three borrowed retiring roots, an unborrowed current, and the reserved
    fifth successor slot, Task 4 must atomically publish/ACK the successor,
    synchronously close old current, and replenish the nonborrowable slot; an
    impossible fourth in-flight borrow is rejected before encode; and
33. with an old presentation child held before command terminal, Task 4 copy and
    root-publication work must run on its independent scheduling path, N+1 must
    ACK, Task 4 backing must remain exactly zero, and the resident retired-
    version union must remain at most eight colors; and
34. the mapping prepass must hold zero Task 4 refs, keep its bitsets/stack/
    descriptors inside the declared fixed W or legacy-scratch partition, reject
    stale Task 4/mapping revisions before acquisition, batch each 3024x1964
    acceptance mapping in at most eight mapping-prepass waves, separately record
    <=256 serialized render commands across all layers/contents, recover a
    worst-case multi-tile descriptor overflow by exact tile-group bisection with
    whole-result discard semantics, and fail a cross-stage page-set
    oracle if either shared precise radial call site is mutated.

Use asymmetric coordinate-colored pixels and both sparse backends where
available. A normal top-layer hash alone is insufficient.

- [ ] **Step 2: Run and confirm the semantic/direct-display failures**

```bash
swift test --filter 'CanvasPresentationCacheTests|GridRendererSparseCutoverTests|InteractiveStrokePresentationCacheTests|CanvasCompositeTileCacheTests|LayerCompositorTests|StageDAcceptanceTests'
```

Expected: the current path still enters `LayerCompositor`; no projected
replacement cache/root exists; lower-layer, erase, transparent-override, and
post-publication retry-debt tests fail.

- [ ] **Step 3: Add narrow owned source captures and projected preview cache**

Extend Task 4 projection state with the exact commit material and add an atomic
exact-revision metadata/fence plus restricted child lease factory without
exposing raw providers. Add Context and SurfaceStore projection-plan
preparation; the plan freezes one ordered epoch/layer stack as provider/reference
metadata and acquires only child-restricted exact leases, with Task4<=8 and
aggregate internal IDs<=8,192. Add the mapping-only precise exact-radial child
authority before relying on that bound; the generic 3x3 radial root
authority is not a proof of one-pixel termination. Build whole identity-mapped canonical RGBA16F P tiles
through the shared bounded tile compositor for only current reachable
transient-dirty coordinates. Refactor Task 5 canonical and Task 6 preview
handles onto one `CanvasPresentationTileStoreCore`; it alone owns the
`2N_F*T+Q` store, `2N_F*T` resident partition, shared workspace,
publications, metadata, and retirement-union accounting. No independent cache
actor may retire shared refs. Add the checked mode/geometry capability policy,
explicit idle/high-water counters, and the transactional at-most-eight-reference
cold-lease primitive before allocating P.

Before any Task 6 ordinary sparse build, add the universal <=4-page leaf and
<=512-binding partition, fixed `C_m` builder, fixed `G_m` host arena, and the
single-parent 64 MiB `P_gpu` physical arena. Bypass retained CPU plan-cache contents and
legacy heap binding arrays on this path. Make >256-draw children terminally
serialized over one unpublished clear/load/final-present target and bind every
GPU content/source token to its root scope through invalidation.

- [ ] **Step 4: Add merged D snapshots, owning roots, and tiled-exact mode**

Construct one mixed-namespace canonical display view D from F/P explicit
presence and create its provider/capture before any retirement. Publish one owning
`CanvasPresentationRoot` through `CanvasPresentationRootStore`; preparations and
submissions hold bounded closeable borrows. Old roots remain borrowable until
their submissions settle and are never force-closed by a swap. Direct preparation
transfers one snapshot-scoped D borrow through the existing canonical sparse
source path. Keep sparse ABI v2 and existing shader roles/layout byte-for-byte.

Add whole-frame tiled-exact roots for failed capability admission. They freeze
the same exact layer/source epoch and encode <=256² output regions with the
shared blend/tile kernel and Task 8 mapping. They must allocate no full-output
scratch, own no Task 4 ACK or presentation-store reference, and serialize their
tile workspace with F/P composition through one command-terminal arbiter.

- [ ] **Step 5: Bootstrap canonical display and route every canonical mutation**

Before direct draw is enabled, apply a full Task 5 bootstrap for the current
empty or imported document and publish initial `(F, nil)`. Until the exact
geometry-specific store/envelope and bootstrap succeed, publish tiled-exact roots
when that capability is admitted, otherwise legacy roots, without failing
renderer startup or shrinking existing pools. Route stroke
commit, layer-stack edits, clear, resize,
history restore, archive/import restore, and every other canonical mutation
through one `enqueueCanonicalSuccessor(base:target:invalidation:)` coordinator.
Metadata-only successors still publish a new owning root with identical tile
references. Do not cut ordinary draw over until bootstrap and transition tests
prove no root is absent or stale.

- [ ] **Step 6: Implement atomic commit, retry debt, and retirement**

For an admitted direct hybrid, successful commit linearizes as:

1. keep the old merged D root (`old F` plus exact P replacement) published;
2. authenticate and reserve the exact promotion/composition union;
3. publish the document transaction;
4. apply the exact hybrid update and obtain `new F`;
5. mint the successor D from `new F`, atomically swap the root, then
6. request successful retirement of Task 4 and old P ownership.

When the final Task 4 revision has no prediction, Context may mint a one-shot
`CanvasCompositeTilePromotionPlan` only after authenticating the exact stroke
epoch/source/material/base identity, P revision, reachability digest, explicit V
coordinates, and commit dirties. `applyHybrid` composes only `dirty − V`, builds
new F as unchanged old refs plus exact promoted P refs at V plus newly composed
refs elsewhere, creates the new F provider/capture before releasing P ownership,
and excludes promoted refs from retirement. Transparent promoted P removes an
old opaque F ref. Old-P and new-F captures may safely retain the same immutable
physical references across an in-flight old display command; retirement waits
for both captures, but promotion does not wait for drawable presentation.

Before the canonical identity claim is acquired, every failure closes candidates
and retains old F/P. After claim acquisition, publication is a nonthrowing field
swap/claim completion. If no authenticated promotable P exists, use normal full
composition or remain tiled-exact; never infer promotion from shared storage.

Hybrid capacity is a pre-Context gate. If retiring D/P references make the
hybrid union inadmissible, publish tiled-exact, drain/drop P as above, and admit a
normal old-F/new-F update before Context publication. Only then may the document
transaction linearize. Discovering this avoidable capacity transition after
Context publication is forbidden.

For that tiled path—and for every source-dependent tiled or legacy canonical
mutation—prepare the target root and acquire its
`CanonicalPresentationPublicationClaim` before Context publication. The Context
linearization and the nonthrowing target-root arm/claim completion form one
coordinator critical section with no suspension point. Replaced stable-source
retirement remains deferred until the target root is current and the base root's
future acquisition gate is closed. Any already-leased base child remains valid
to terminal; no later child can reacquire a replaced base reference.

Publication and retirement are separate. No frame may see blank content, double
paint, `new F + P`, or `old F + nil` after document publication.

Document publication is irreversible. If hybrid application/root publication
then fails, keep the old direct D visible and retain exact F/P/epoch/captures as
durable retry debt. If a direct-capable fallback armed the target tiled root but
also consumed a pre-reserved Task 5/F identity claim, keep that exact target root
visible and retain only that authenticated F/direct-successor claim; the base
tiled root is not redrawable authority after its sources are replaced, and the
state must not be described as `(old F, P)` after P was deliberately drained.
Those two cases remain non-idle, may not report cancellation or terminal
operation success/failure, and fence later canonical mutations until the exact
claim settles; otherwise a later Context mutation could revoke its base→target
authority. Retry the exact successor until publication succeeds or shutdown
reports the unresolved debt.

By contrast, when tiled-only or legacy capability has no admitted presentation
store and no pre-reserved F/direct claim, the nonthrowing Context+target-root arm
is the canonical mutation's terminal success. Complete Task 4 retirement and the
operation result after its ordinary root/source latches settle, admit the next
canonical mutation, and report idle without manufacturing canonical-cache or
direct-reentry debt. A later capability probe/full bootstrap is a separate,
latest-identity, coalescible optimization: it cannot retain this operation's
claim, fence later mutations, or make shutdown report this mutation as pending.
This mode-qualified settlement applies to strokes and every non-stroke mutation.
A no-op commit publishes `(same F, nil)` in direct mode; tiled/legacy instead arm
an exact same-canonical target root without the transient revision, then retire
Task 4 successfully. Pre-publication cancellation leaves canonical unchanged and
uses cancellation retirement.

- [ ] **Step 7: Cut ordinary draw over and verify no full-output scratch**

Remove the full-output `prepareLayerDisplaySubmission` path from admitted
tiled/direct `GridRenderer.draw(in:)` dispatch and delete the legacy
ACK-owning raw-transient display-source route. Direct roots sample the one merged
canonical D source; tiled-exact roots use the same bounded layer/tile kernel in
<=256² output regions. Retain an explicitly scoped root-owned legacy normal-draw
branch below the tiled threshold; on qualified hardware, retain the old
full-output `LayerCompositor` API for stable capture/export only. Extend idle diagnostics
with capability/mode, shared-store unique physical union, resident/backing/
provisional/cleanup/persistent-zero bytes, metadata, preview/root/retry,
tiled-exact workspace, cold-lease chunks, and submission ownership.

```bash
swift test --filter 'CanvasPresentationCacheTests|GridRendererSparseCutoverTests|InteractiveStrokePresentationCacheTests|CanvasCompositeTileCacheTests|PaintTileResidencyTests|PaintTileSnapshotRetentionTests|LayerCompositorTests|StageDAcceptanceTests|ShaderABILayoutTests|SparseTileSamplingPlanTests|SparseTileSamplingPipelineTests|DocumentPaintStableSnapshotRendererTests|PeriodicRepeatExportTests'
swift build -c release --target MetalRenderer
git diff --check
```

Expected: all semantic counterexamples pass; the >4,194,304-pixel frame has zero
interactive full-output scratch; nil drawable does not gate progress; every
terminal path reaches exact zero ownership; post-publication failures remain
visible/retryable rather than pretending cancellation.

- [ ] **Step 8: Independent review and commit**

Require a whole-diff Critical/Important review covering semantic layer parity,
transparent presence, root linearization, failure-after-publication debt,
budgets, and affine ownership. Record all RED/GREEN evidence and checked preview
partition in `task-6-report.md`, then commit as `feat: present projected canvas tiles`.

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
- Consumes: `CompiledPeriodicDisplayFold` from Task 7. Its current stable,
  compositor, and flattened-export consumers are independent of Task 6.
- Produces: the periodic output-mapping/sparse-sampling ABI consumed by the
  corrected Task 6 merged-D and tiled-exact display paths.

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
func testQualified3024x1964RectangularChildBudget()
func testQualified3024x1964RadialChildBudget()
```

The sustained-stroke test holds a real mouse drag and polls the incrementally readable JSONL before pointer-up; it requires multiple authoritative inputs and at least two actual presented events. The maximize test first requires that the hardware admitted `.tiledExact` or `.directProjected`, fails if such hardware enters legacy, then requires drawable area above 4,194,304 pixels, zero interactive full-drawable scratch bytes, a presented frame, and no error banner/record. The resize test maximizes/restores and zooms during a drag, then checks revision compatibility and zero terminal ownership. The two 3024x1964 routes force dense maximum-role rectangular and compiler-admitted finite-radial fixtures in both direct and tiled modes; every submitted/presented record carries the Task 6 stream receipt and must show at most eight mapping-prepass waves and at most 256 serialized child commands across all layers/contents.

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
    public let maximum3024x1964MappingPrepassWaves: UInt16
    public let maximum3024x1964SerializedChildCommands: UInt64
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

For 120 Hz, submit p95/p99 limits are 8/12 ms; for 60 Hz they are 12/16.7 ms. Present p95/p99 limits are two/three refresh intervals, every authoritative sample is at most 100 ms, missed deadlines are at most 1% with no run above two, brush preparation p95 is below 2 ms, backlog settles within two refresh intervals, and final-five-minute RSS slope is at most 1 MiB/min with post-settle RSS within the larger of 10% or 64 MiB of warm baseline. Dedicated 3024x1964 maximum-role rectangular/radial records additionally require `mappingPrepassWaveCount <= 8`, `serializedChildCommandCount <= 256`, monotonically complete covered-layer/pixel work, and the same end-to-end submit/present limits; missing receipt fields fail closed.

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
5. Run the six short shipping regressions, including both 3024x1964 child-budget routes, as smoke.
6. Run the two 3024x1964 maximum-role routes long enough to collect stable direct+tiled latency distributions and validate their 8-wave/256-command bounds.
7. Run `testTrueTenMinuteMixedShippingSession` for 600 measured wall seconds at 2048x2048, then separately at 4096x4096.
8. Poll the JSONL heartbeat at least every five seconds and terminate a stalled run while preserving evidence.
9. Repeat correctness/ownership with Metal validation enabled; run latency with it disabled.
10. Preserve JSONL, stdout/stderr, `.xcresult`, validation JSON, commit/digest, OS/GPU/display/backing/input metadata, and exact commands.
11. Label every shortened duration `SMOKE ONLY — NOT ACCEPTANCE` and forbid it from producing `passed: true`.

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
4. Tasks 4 and 5 may be reviewed independently, but both must pass before Task 6 removes ordinary `LayerCompositor` display in admitted tiled/direct capability.
5. Task 8 requires Task 7 and publishes the fold/display ABI independently;
   corrected Task 6 consumes completed Tasks 4, 5, and 8.
6. Task 9 requires Tasks 1, 3, 6, and 8; Task 10 requires Task 9; Task 11 is the final verification/review/evidence gate.
7. After every task, run `git diff --check`, inspect unrelated changes, and request a behavioral review before moving to the next dependency boundary.

## Spec Coverage Review

- Worker/drawable decoupling and exact settlement: Tasks 4 and 6.
- Dirty-proportional canonical and transient work with bounded memory: Tasks 4-6.
- No qualified tiled/direct ordinary full-drawable scratch, with explicit legacy
  capability classification below threshold: Task 6 plus shipping proof in
  Tasks 9-11.
- Immutable geometry/tiling/layer/transient/viewport/drawable revisions and latest-wins retirement: Tasks 2-3 and 6.
- Complete CPU/GPU fold and flattened export parity: Tasks 7-8.
- Frame starvation repair without permanent render loop: Task 3.
- Per-input event-to-present production telemetry and incremental progress: Tasks 1 and 9.
- Correct failure classification and zero idle ownership: Tasks 3-6 and validator Task 10.
- Exact Release executable, latency/backlog/deadline/RSS/endurance gates: Tasks 9-11.
- Physical Mac/tablet qualification and 1x/2x plus 0.25x/1x/8x matrix: Task 11.
- Krita replacement, new brush families, and brush-feel retuning remain excluded by Global Constraints.
