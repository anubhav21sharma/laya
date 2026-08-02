# Brush Engine Corrective Program Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Laya's replay-heavy, main-actor-bound live stroke path with an
incremental and measured architecture, establish the missing input, color,
surface, and backend contracts, then rebuild Technical Ink, Graphite Pencil,
Natural Charcoal, and Chisel Marker until they pass automated functional,
software-performance, and explicit manual-quality gates.

**Architecture:** Keep logical dab generation deterministic and before
symmetry. A non-main-actor `StrokeRenderCoordinator` owns authoritative stroke
state and emits only new ordinal-tagged dabs into an append-only live surface.
Prediction uses a separate replaceable overlay. The main actor forwards input,
publishes editor state, and composites prepared surfaces; it does not replay or
prepare the stroke. Brush definitions compile ordered multi-sensor dynamics,
tip-support metadata, and a statically registered backend. Paint is blended in
premultiplied linear sRGB on bounded, tile-backed working surfaces. Existing
canonical commit, one-command history, cancel, tiling, and symmetry invariants
remain intact.

**Tech Stack:** Swift 6.0 with complete concurrency checking, Swift Testing,
Metal/MetalKit, CoreGraphics/ImageIO, SafeArchive/PatternFile, XcodeGen 2.46+,
macOS 14+, and iPadOS 18+.

## Authority And Status

This plan implements the independently validated findings in
`docs/superpowers/reports/2026-08-01-brush-engine-corrective-report.md` plus the
additional repository-confirmed gaps recorded during the external-analysis
audit. The approved author-supplied charcoal corpus is governed by
`docs/superpowers/specs/2026-08-01-authored-procreate-charcoal-corpus-design.md`
and
`docs/superpowers/plans/2026-08-01-authored-procreate-charcoal-corpus.md`.
It supersedes the completion claims in:

- `docs/superpowers/plans/2026-07-30-professional-dry-media-stage5.md`;
- `docs/superpowers/plans/2026-07-30-stage5-evidence-review-fixes.md`; and
- `docs/superpowers/milestones/12-professional-dry-media.md`.

Those files remain historical records. The archived external reports under
`docs/superpowers/archive/external/2026-08-01/` are provenance only and have no
normative authority.

No iPad is currently available. All pure, headless Metal, macOS app,
instrumentation, sustained-load, and simulator work proceeds now. Pencil feel,
120 Hz presentation, thermal behavior, and iPad memory qualification remain
explicitly `pendingPhysicalProfile`; they do not block software engineering,
but they do block `physicalProfilePassed` and `productAccepted`.

## Global Constraints

- Execute directly on `main`; do not create a worktree.
- Preserve unrelated user files, including `.vscode/`. Stage only files owned
  by the active task.
- Write the failing test or functional assertion before each behavior change.
- Run focused tests after each red/green step and the full suite at every stage
  boundary. Metal tests may skip only when no Metal device exists.
- `PatternEngine` remains platform- and renderer-independent.
- Canonical pixels remain the source of truth. Preview surfaces are transient.
- One completed stroke produces exactly one history command. Cancel produces
  none and never changes canonical pixels.
- Authoritative actual/coalesced samples alone determine committed output.
  Prediction can be shortened or disabled under pressure without changing it.
- Each logical dab is generated once in world space before symmetry or tiling,
  receives a monotonic ordinal, and is deposited at most once per projected
  destination.
- Ordinary dry brushes never replay the completed stroke body and never infer
  a long retroactive taper on pointer-up.
- Input callbacks perform bounded copying/enqueue only. They do not compile,
  decode, allocate textures, wait for the GPU, validate the full retained
  stroke, or encode historical paint.
- Overload is reported. It must not silently drop authoritative dabs, widen
  spacing, remove texture, or alter dynamics.
- The app uses a compile-time backend registry. Dynamic executable brush
  plugins are outside the iPad security and distribution model.
- GPL Krita code is not copied or translated. Only clean-room architectural
  ideas confirmed from behavior and documented source inspection may be used.
- A checked-in raster is not a golden reference merely because current code
  produced it. Independent metrics and manual review decide visual acceptance.
- Optimizations not supported by a profile—HSV micro-optimization, universal
  mask padding, per-dab validation removal, blanket LOD changes—stay out.
- Physical iPad/Wacom absence is a pending evidence state, never a fabricated
  pass or a reason to stop software work.
- Manual brush review is deferred until every corrective stage and the full
  post-Stage-G automated performance round finish. Pending manual cards do not
  block implementation, but they do block product admission.

## Locked Technical Decisions

1. **Authoritative deposition is append-only.** `replayTail` survives only as
   an isolated legacy/special-correction compatibility mode and cannot be used
   by the rebuilt four professional dry brushes.
2. **Prediction is a separate surface.** Clearing or replacing it cannot touch
   authoritative live paint.
3. **The main actor is a facade.** Stroke generation, projection, dirty-tile
   derivation, queue management, and private-surface encoding live in a serial
   non-main-actor coordinator. `MTKView` state and final display composition
   remain on the main actor.
4. **Color math is explicit.** Document colors enter/leave as encoded sRGB;
   paint and layer equations operate on premultiplied linear-sRGB values.
   Paint-bearing working tiles use `rgba16Float`; display/export targets use an
   sRGB pixel format or explicit transfer conversion.
5. **High precision is tile-backed.** A 256 x 256 sparse tile is the allocation
   unit. Full-canvas RGBA16F textures per layer are forbidden. Residency is
   byte-budgeted, measured, and independent of document dimensions.
6. **Dynamics are ordered programs.** Schema-v2 outputs accept up to four
   ordered sensor terms. Schema-v1 mappings compile through an exact adapter.
7. **Speed safety and artistic normalization are different.** The 100,000
   world-unit ceiling remains validation protection; it is never the default
   artistic full-scale speed.
8. **Timed deposition consumes recorded time.** No generator reads wall-clock
   time internally. Replaying the same timestamped trace produces identical
   dabs.
9. **Tip support drives spacing and cursor truth.** Nominal diameter, visible
   alpha support, and directional footprint are separate quantities.
10. **Wet/ordered interaction is a distinct backend.** The corrective dry path
    does not pretend destination sampling is already implemented. This plan
    installs the boundary and removes misleading dead flags; a later wet-media
    plan implements the ordered interaction kernels.
11. **The first charcoal source is an approved authored corpus.** The replacement
    `FREE Charcoal Set` supplies `C Charcoal` (`CC70504F-0D16-4D26-88A6-BF47BDA8ADE8`)
    as the primary target and `C Charcoal Soft`
    (`21AF8C6B-3FB1-4BF8-8F89-F5768271DA35`) as a secondary target. Both are
    parent-plus-`Sub01` composite brushes whose referenced Procreate tip and
    grains are absent. Laya therefore adds bounded active-sub-brush parsing,
    a native composite dry-brush contract, and project-owned replacements
    reported as approximations. Runtime code remains wholly native.
12. **Testing is clustered but mandatory.** Focused red/green tests remain per
    task. Heavy functional/performance checkpoints run after Stages B, E, F,
    and G, followed by one full post-Stage-G performance round. Bugs may be
    repaired at the next checkpoint, but no work is declared delivered before
    every applicable automated gate is green.

## Finding-To-Task Coverage

| Independently confirmed issue | Corrective tasks |
| --- | --- |
| Actual input replays retained stroke history | 5, 6, 7, 23 |
| Whole CPU live-stroke path is serialized on `MainActor` | 5, 7, 23 |
| Prediction and correction contaminate authoritative work | 4, 6 |
| Pointer-up causes aggressive retroactive taper/retreat | 4, 19 |
| Cursor shows nominal size instead of evaluated support | 15, 16 |
| Speed uses a safety ceiling as artistic normalization | 8 |
| One sensor per output blocks natural response composition | 9 |
| Direction initialization/filtering creates broad-tip artifacts | 10, 22 |
| Simple stabilization cannot express quality/latency tradeoffs | 10 |
| No deterministic stationary/timed emission contract | 11 |
| Spacing ignores anisotropic directional footprint | 11 |
| Current paint blending has no explicit linear color contract | 12, 13 |
| High-precision full-surface storage would exceed device budgets | 13, 14 |
| Layer model exists in files but not the runtime compositor | 14 |
| Tip support/mip/cache policy is incomplete | 15 |
| Backend/destination-sampling capability is misleading | 17 |
| Authored charcoal uses independent parent/sub-brush behavior that shape/grain layers cannot represent | 18, 22 |
| Diagnostics and reference code inflate production ownership | 19 |
| `GridRenderer` owns too many live-stroke responsibilities | 5–7, 23 |
| Four presets pass internal gates but fail user-visible quality | 1–3, 19–22 |
| Evidence gates miss production UI behavior and honest status | 2, 3, 24–26 |

## Delivery Graph

```text
Stage A: truthful status + failing evidence
    -> Stage B: causal incremental runtime
        -> Stage C: input/dynamics/spacing contracts
            -> Stage D: color + tiled surface + composition
                -> Stage E: resources + backend boundaries
                    -> Stage F: rebuild one brush at a time
                        -> Stage G: integration + acceptance
```

Stages are sequential because each changes the behavior against which the next
stage is calibrated. Tasks within a stage may use independent subagents only
where their file ownership does not overlap; merge and full-stage verification
remain serial.

## Clustered Test Checkpoints

- **After Stage B:** endpoint causality, prediction isolation, long-stroke
  complexity, backlog, event-to-submit latency, and production-path frame data.
- **After Stage E:** dynamics/input contracts, cursor/support agreement,
  resource decode/upload/cache behavior, color/surface correctness, memory
  bounds, and app-control responsiveness.
- **After Stage F:** exhaustive four-family raster quality, visibility, width,
  texture spectrum, buildup, turns, seams, symmetry, erasing, negative
  controls, and nominal/large-size software performance.
- **After Stage G:** real-app cross-family automation, sustained load, cache
  churn, memory pressure, Debug/Release/simulator builds, and regression suite.
- **Post-Stage G:** rerun the complete performance matrix three times, fix every
  software failure, then perform one user manual-quality round. Manual findings
  may reopen implementation; they never retroactively turn a failed automated
  gate green.

## Core Interfaces

The implementation converges on these interfaces. Names and ownership are
fixed by this plan; internal helper layout may change during red/green/refactor.

```swift
public struct StrokeRenderConfiguration: Sendable {
    public let brush: CompiledBrushRenderState
    public let intent: StrokeIntent
    public let projection: CompiledProjection
    public let surfaceDescriptor: StrokeSurfaceDescriptor
}

public actor StrokeRenderCoordinator {
    public func begin(
        configuration: StrokeRenderConfiguration,
        initialSamples: [StrokeSample]
    ) async throws -> StrokeRuntimeSnapshot

    public func append(
        actualSamples: [StrokeSample],
        predictedSamples: [StrokeSample]
    ) async throws -> StrokeRuntimeSnapshot

    public func prepareFrame(
        budget: StrokeFrameBudget
    ) async throws -> PreparedStrokeFrame?

    public func finish(
        finalActualSamples: [StrokeSample]
    ) async throws -> StrokeCommitPayload

    public func cancel() async
}
```

```swift
public struct BrushSensorProgram: Codable, Equatable, Sendable {
    public let speed: BrushSpeedNormalization
    public let outputs: [BrushDynamicOutput: BrushResponseProgram]
}

public struct BrushResponseProgram: Codable, Equatable, Sendable {
    public let baseValue: Float
    public let terms: [BrushResponseTerm] // validated count: 0...4
}

public struct BrushResponseTerm: Codable, Equatable, Sendable {
    public let input: BrushDynamicsInput
    public let curve: BrushResponseCurve
    public let operation: BrushResponseOperation
    public let scale: Float
}
```

```swift
public enum BrushBackendKind: String, Codable, Sendable {
    case deposition
    case canvasInteraction
    case continuousRibbon
}

public struct BrushBackendRegistration: Sendable {
    public let kind: BrushBackendKind
    public let schemaVersion: UInt16
    public let compiler: any BrushBackendCompiler
}
```

```swift
public enum DocumentWorkingColorSpace: String, Codable, Sendable {
    case linearSRGB
}

public struct RasterTileID: Hashable, Codable, Sendable {
    public let layer: LayerID
    public let x: Int
    public let y: Int
}

public protocol PaintTileStore: Sendable {
    func read(_ id: RasterTileID) async throws -> PaintTileSnapshot?
    func beginMutation(_ ids: Set<RasterTileID>) async throws -> PaintTileTxn
    func commit(_ transaction: PaintTileTxn) async throws -> RasterRevision
    func cancel(_ transaction: PaintTileTxn) async
}
```

---

## Stage A — Restore Truthful Status And Freeze The Failures

### Task 1: Remove The Broken Presets From Product Acceptance

**Files:**

- Modify: `Sources/EditorCore/Brushes/EditorBrushCatalog.swift`
- Modify: `Sources/EditorCore/Brushes/ProfessionalBrushCatalog.swift`
- Modify: `App/PatternSpike/BrushLab/BrushLabSession.swift`
- Modify: `Tests/EditorCoreTests/ProfessionalBrushCatalogTests.swift`
- Modify: `App/Tests/BrushLabSessionTests.swift`
- Modify: `docs/superpowers/milestones/12-professional-dry-media.md`
- Modify: `docs/superpowers/16-reference-sheet.md`

**Behavior:** Keep the four definitions available only to Brush Lab as
`correctiveRebuildRequired`. Remove them from `EditorBrushCatalog.drawEntries`
and restore the vetted anchor ink as `defaultDraw`. Persisted professional IDs
must resolve to a laboratory-only entry with a clear message instead of
silently selecting a different brush.

- [ ] Add catalog tests proving none of the four IDs is product-selectable,
  all remain resolvable in Brush Lab, and a persisted ID reports laboratory
  status.
- [ ] Add `ProfessionalBrushStatus.correctiveRebuildRequired` and route the
  four entries through it.
- [ ] Change milestone language from completed/realtime120 to corrective work
  required; retain old counts only as historical evidence.
- [ ] Run `swift test --filter 'ProfessionalBrushCatalogTests|BrushLabSessionTests'`.
- [ ] Commit as `fix(brush): revoke broken preset acceptance`.

### Task 2: Convert User Reports Into Failing Functional Fixtures

**Files:**

- Modify: `Sources/PatternEngine/Verification/StrokeTraceFixtures.swift`
- Create: `Sources/MetalRenderer/BrushValidation/BrushFunctionalMetrics.swift`
- Create: `Tests/MetalRendererTests/BrushCorrectiveFunctionalTests.swift`
- Modify: `Tests/PatternEngineTests/ProfessionalStrokeTraceTests.swift`
- Modify: `App/PatternSpike/Harness/Scenes/professional-technical-ink.json`
- Modify: `App/PatternSpike/Harness/Scenes/professional-graphite-pencil.json`
- Modify: `App/PatternSpike/Harness/Scenes/professional-natural-charcoal.json`
- Modify: `App/PatternSpike/Harness/Scenes/professional-chisel-marker.json`

**Required metrics:**

```swift
struct BrushFunctionalMeasurement: Codable, Equatable, Sendable {
    let changedPixelCount: Int
    let alphaSupportBounds: PixelBounds?
    let centerlineWidthP50: Float
    let centerlineWidthP95: Float
    let alphaP50: Float
    let alphaP90: Float
    let endpointRetreatPixels: Float
    let turnProtrusionPixels: Float
    let isolatedComponentCount: Int
}
```

- [ ] Check in timestamped direct traces for a 10-second Technical Ink line, a
  fast-release ink stroke, 40 px Graphite, neutral-pressure Charcoal, and a
  90-degree plus circular Chisel turn.
- [ ] Implement measurements from readback pixels using independent scalar CPU
  code; do not call brush dynamics or shader helpers to compute expected data.
- [ ] Add assertions that currently fail for retained-body replay, endpoint
  retreat, Graphite cursor/support mismatch, Charcoal visibility, and Chisel
  protrusions.
- [ ] Preserve current rasters under `.build/brush-corrective-baseline/` as
  failure evidence, never under an approved golden directory.
- [ ] Run `swift test --filter 'BrushCorrectiveFunctionalTests|ProfessionalStrokeTraceTests'`
  and record the expected failures in the task report.
- [ ] Commit as `test(brush): freeze reported functional failures`.

### Task 3: Make Performance Evidence Measure The Production Path

**Files:**

- Create: `Sources/MetalRenderer/StrokeRuntime/StrokeRuntimeTelemetry.swift`
- Modify: `Sources/MetalRenderer/Deposition/DepositionTelemetry.swift`
- Modify: `Sources/MetalRenderer/BenchmarkRecord.swift`
- Modify: `App/PatternSpike/Debug/DebugPerformanceMonitor.swift`
- Modify: `App/PatternSpike/Debug/DebugPerformanceHUD.swift`
- Modify: `App/PatternSpike/Harness/HarnessLaunch.swift`
- Create: `Tests/MetalRendererTests/StrokeRuntimeTelemetryTests.swift`
- Modify: `App/Tests/DebugPerformanceMonitorTests.swift`

**Telemetry contract:** Record session/stroke IDs, input provenance counts,
new logical/projected dab counts, authoritative and predicted replay counts,
queue depth/high-water, prepare/submit/GPU/presentation timestamps, frame p95,
missed-frame fraction, cache hits/misses, and memory high-water. JSONL writes
are buffered off the input path. The compact HUD shows current/target FPS,
frame p95, prepare p95, submit p95, GPU p95, actual/predicted queue depth, and
logging state.

- [ ] Write aggregation tests using a deterministic synthetic timestamp source.
- [ ] Add begin/end segment markers so a user session can be isolated from logs.
- [ ] Add a 10-second and accelerated 10-minute production-renderer trace.
- [ ] Fail the software gate when actual replay is nonzero for an append-only
  brush, backlog grows monotonically, or event-to-submit misses exceed 1%.
- [ ] Run `swift test --filter 'StrokeRuntimeTelemetryTests|DebugPerformanceMonitorTests|BenchmarkRecordTests'`.
- [ ] Commit as `feat(perf): measure live stroke pipeline`.

**Stage A exit:** The app and docs no longer claim the four brushes are done;
all five user-visible failures reproduce through stable traces; a production
session yields attributable performance logs.

---

## Stage B — Replace Replay With A Causal Incremental Runtime

### Task 4: Make Stroke Termination Causal

**Files:**

- Modify: `Sources/PatternEngine/BrushRecipe.swift`
- Modify: `Sources/PatternEngine/BrushModel/BrushDefinition.swift`
- Modify: `Sources/PatternEngine/BrushModel/BrushProgram.swift`
- Create: `Sources/PatternEngine/BrushTerminationEvaluator.swift`
- Modify: `Sources/PatternEngine/BrushDynamicsEngine.swift`
- Modify: `Sources/PatternEngine/BrushStrokeGenerator.swift`
- Modify: `Tests/PatternEngineTests/BrushDefinitionTests.swift`
- Modify: `Tests/PatternEngineTests/BrushDynamicsEngineTests.swift`
- Create: `Tests/PatternEngineTests/BrushTerminationEvaluatorTests.swift`

**Behavior:** Schema-v2 dry brushes use `.cap`, `.pressureRelease(maximumWorldLength:)`,
or `.boundedCorrection(maximumSamples:maximumWorldLength:maximumDabs:)`.
`.cap` and `.pressureRelease` never reevaluate an already deposited ordinal.
Legacy schema-v1 end taper compiles only through the compatibility adapter and
cannot be selected by a rebuilt professional definition.

- [ ] Add red tests asserting pointer-up cannot change body dabs, endpoint
  retreat is at most 1 logical pixel for `.cap`, and correction limits reject
  excess samples, distance, or dabs.
- [ ] Introduce `BrushTerminationDefinition` and compile it into an immutable
  `BrushTerminationProgram`.
- [ ] Delete the product-path call that reevaluates the complete stroke after
  total length becomes known.
- [ ] Keep schema-v1 decode compatibility behind a named legacy adapter and
  characterize its old pixels.
- [ ] Run `swift test --filter 'Brush(Definition|DynamicsEngine|TerminationEvaluator)Tests'`.
- [ ] Commit as `fix(brush): make stroke termination causal`.

### Task 5: Introduce Append-Only Authoritative Stroke State

**Files:**

- Create: `Sources/MetalRenderer/StrokeRuntime/StrokeRenderCoordinator.swift`
- Create: `Sources/MetalRenderer/StrokeRuntime/AuthoritativeStrokeQueue.swift`
- Create: `Sources/MetalRenderer/StrokeRuntime/StrokeRenderState.swift`
- Modify: `Sources/PatternEngine/TransientStrokeBuffer.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Create: `Tests/MetalRendererTests/StrokeRenderCoordinatorTests.swift`
- Modify: `Tests/PatternEngineTests/TransientStrokeBufferTests.swift`

**Behavior:** `append(actualSamples:)` emits only ordinals not previously
returned. `AuthoritativeStrokeQueue` is capacity-bounded and tracks high-water.
Successfully submitted ordinals are retired and can never re-enter a frame.
The coordinator retains generator state and compact commit metadata, not a
renderable copy of the completed dab body.

- [ ] Add tests for 1, 10, 1,000, and 100,000 input events proving each ordinal
  is emitted and submitted once and per-event returned work does not grow with
  stroke age.
- [ ] Add batching-invariance tests: one batch versus arbitrary subdivisions
  must produce identical ordered authoritative dabs and canonical pixels.
- [ ] Extract a sendable immutable `CompiledBrushRenderState` from the
  main-actor `CompiledBrush`; isolate immutable Metal references in one audited
  `@unchecked Sendable` resource holder if the SDK lacks conformances.
- [ ] Route one compatibility ink brush through the coordinator while retaining
  the old path behind a debug-only A/B switch.
- [ ] Remove ordinary actual-input calls to `rebuildReplayLayer` and equivalent
  retained-body encoding.
- [ ] Run `swift test --filter 'StrokeRenderCoordinatorTests|TransientStrokeBufferTests|DepositionMetamorphicTests'`.
- [ ] Commit as `refactor(render): append authoritative stroke work`.

### Task 6: Isolate Replaceable Prediction

**Prerequisite:** Complete Task 5A in
`docs/superpowers/plans/2026-08-02-renderer-event-dispatcher.md`. Task 5A
centralizes all public renderer callbacks behind a bounded-retention,
generation-aware, non-reentrant dispatcher and closes the remaining Task 5
review findings before prediction adds another stroke-scoped producer.

**Files:**

- Create: `Sources/MetalRenderer/StrokeRuntime/PredictionOverlay.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokeRenderCoordinator.swift`
- Modify: `Sources/MetalRenderer/Deposition/FrameScheduler.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Create: `Tests/MetalRendererTests/PredictionOverlayTests.swift`
- Modify: `Tests/MetalRendererTests/DepositionMetamorphicTests.swift`

**Behavior:** Prediction owns its own surface and previous dirty-tile set.
Replacement clears only those tiles, then draws the bounded predicted suffix.
Actual input invalidates prediction from the matching provenance boundary.
Prediction is never promoted as canonical truth.

- [ ] Write tests proving prediction on/off and arbitrary replacement cadence
  produce byte-identical committed output.
- [ ] Set caps to 64 normalized samples, 512 logical dabs, and the frame
  profile's predicted-instance budget; exceeding them truncates prediction
  only and records overload.
- [ ] Implement tile-local clear/rebuild for the prediction overlay.
- [ ] Ensure pointer-up discards prediction before draining final actual work.
- [ ] Run `swift test --filter 'PredictionOverlayTests|DepositionMetamorphicTests|DepositionRendererTests'`.
- [ ] Commit as `feat(render): isolate prediction overlay`.

### Task 7: Move Preparation Off Main And Add Frame Backpressure

**Files:**

- Create: `Sources/MetalRenderer/StrokeRuntime/StrokeInputQueue.swift`
- Create: `Sources/MetalRenderer/StrokeRuntime/StrokeFrameScheduler.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokeRenderCoordinator.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `App/PatternSpike/Canvas/InteractiveMetalView.swift`
- Modify: `App/PatternSpike/Canvas/MetalCanvas.swift`
- Create: `Tests/MetalRendererTests/StrokeFrameSchedulerTests.swift`
- Modify: `Tests/MetalRendererTests/InteractiveFrameTimestampTests.swift`

**Ownership after this task:** The main actor normalizes/copies a platform
event into a bounded message, forwards it, and later composites a prepared
surface. The coordinator actor performs stabilization, spacing, dynamics,
projection, dirty-tile derivation, queueing, and private-surface command
encoding. Drawable acquisition stays late in `draw(in:)`.

- [x] Add an executor-probe test proving generator and projection work do not
  execute on `MainActor` and strict concurrency reports no unsafe capture.
- [x] Add deterministic scheduler tests for 60/120 Hz budgets, queue high-water,
  drain-before-commit, overload, cancellation, and prediction shedding.
- [x] Use preallocated ring buffers; an authoritative-capacity failure cancels
  the stroke with a typed error rather than dropping or mutating dabs.
- [x] Pause `MTKView` when no stroke, viewport animation, pending composite, or
  HUD sample requires a frame; request a draw on invalidation.
- [x] Keep the debug A/B route until parity, history, cancel, tiling, and
  symmetry tests pass, then delete the old runtime.
- [x] Run `swift test --filter 'StrokeFrameSchedulerTests|StrokeRenderCoordinatorTests|InteractiveFrameTimestampTests|DepositionRendererTests'`.
- [x] Run the 10-minute trace and assert bounded memory plus flat per-event CPU
  work between the first and last deciles.
- [x] Commit as `perf(render): move stroke preparation off main`.

**Stage B exit:** Task 5A's renderer event dispatcher is independently clean;
long strokes have O(new work) CPU behavior, zero actual replay, bounded memory
and queues, isolated prediction, causal endpoints, and the existing
preview/commit/cancel/history/symmetry matrix passes.

Accepted on 2026-08-02. See
[`2026-08-02-stage-b-acceptance.md`](../reports/2026-08-02-stage-b-acceptance.md).

---

## Stage C — Make Input, Dynamics, Direction, And Spacing Physically Coherent

### Task 8: Separate Velocity Safety From Artistic Speed

**Files:**

- Modify: `Sources/PatternEngine/BrushInput.swift`
- Create: `Sources/PatternEngine/StrokeVelocityFilter.swift`
- Create: `Sources/PatternEngine/BrushSpeedNormalization.swift`
- Modify: `Sources/PatternEngine/BrushDynamicsEngine.swift`
- Modify: `Sources/PatternEngine/BrushModel/BrushDefinition.swift`
- Create: `Tests/PatternEngineTests/StrokeVelocityFilterTests.swift`
- Modify: `Tests/PatternEngineTests/BrushDynamicsEngineTests.swift`

**Behavior:** `BrushInputContract.maximumWorldVelocity` remains the malformed-
input clamp. Every schema-v2 definition declares a positive artistic
`fullScaleWorldVelocity`. Velocity is derived from a deterministic 40 ms
weighted sample window, ignores zero/negative timestamp deltas, and is
evaluated in world units so zoom changes do not change dynamics.

- [ ] Add traces with timestamp jitter, coalescing, zoom changes, and one
  malformed velocity spike; assert smooth bounded normalized values.
- [ ] Add `BrushSpeedNormalization(fullScaleWorldVelocity:minimumDeltaTime:)`
  and reject values above the safety ceiling.
- [ ] Replace the current default `speedReference = maximumWorldVelocity` with
  the compiled brush's artistic normalization.
- [ ] Characterize schema-v1 behavior through an explicit legacy default; do
  not silently alter saved definitions.
- [ ] Run `swift test --filter 'StrokeVelocityFilterTests|BrushDynamicsEngineTests|BrushDefinitionTests'`.
- [ ] Commit as `fix(input): normalize artistic stroke speed`.

### Task 9: Add Ordered Multi-Sensor Dynamics Programs

**Files:**

- Create: `Sources/PatternEngine/BrushModel/BrushSensorProgram.swift`
- Modify: `Sources/PatternEngine/BrushModel/BrushDefinition.swift`
- Modify: `Sources/PatternEngine/BrushModel/BrushProgram.swift`
- Modify: `Sources/PatternEngine/BrushModel/BrushProgramCompiler.swift`
- Modify: `Sources/PatternEngine/BrushDynamicsEngine.swift`
- Modify: `Sources/BrushFormat/BrushPackage.swift`
- Create: `Tests/PatternEngineTests/BrushSensorProgramTests.swift`
- Modify: `Tests/BrushFormatTests/BrushPackageCodecTests.swift`

**Behavior:** Each dynamic output starts with a base value and applies zero to
four serialized terms in order. Allowed operations are `replace`, `multiply`,
`add`, `minimum`, and `maximum`; each step clamps only where its output contract
requires. Missing optional inputs use the authored neutral value. Dictionary
or set iteration never determines term order.

- [ ] Add compiler/evaluator tests for pressure x tilt, pressure + speed,
  direction x rotation, missing tilt, term-order sensitivity, and schema-v1
  single-mapping parity.
- [ ] Bump native brush schema to v2 and add a deterministic v1-to-v2 compiler
  adapter without rewriting source packages on read.
- [ ] Compile curves to fixed sampled tables before activation; no curve
  allocation or validation occurs during a stroke.
- [ ] Extend semantic hashing and package validation to include ordered terms.
- [ ] Run `swift test --filter 'BrushSensorProgramTests|BrushDefinitionTests|BrushPackageTests'`.
- [ ] Commit as `feat(brush): compile multi-sensor dynamics`.

### Task 10: Stabilize Direction And Paths Without Endpoint Surprises

**Files:**

- Create: `Sources/PatternEngine/BrushDirectionTracker.swift`
- Create: `Sources/PatternEngine/StrokeStabilizer.swift`
- Modify: `Sources/PatternEngine/BrushStrokeGenerator.swift`
- Modify: `Sources/PatternEngine/BrushModel/BrushDefinition.swift`
- Create: `Tests/PatternEngineTests/BrushDirectionTrackerTests.swift`
- Create: `Tests/PatternEngineTests/StrokeStabilizerTests.swift`

**Behavior:** Direction is the shortest-angle-filtered tangent of the stabilized
path. The first direction-dependent dab waits for the first nonzero segment,
then uses that tangent; it does not jump from a fixed zero angle. Schema-v2
stabilization is one of `.none`, `.weightedWindow(distance:)`, or
`.delayed(distance:)`. Technical Ink uses a short weighted window; delayed
stabilization is opt-in and its lag is shown to the authoring tool.

- [ ] Add wraparound tests for 359 degrees to 1 degree, tight corners,
  stationary input, reversal, and first-segment initialization.
- [ ] Add endpoint tests proving weighted stabilization reaches the final
  actual sample within 1 logical pixel and delayed mode reports its authored
  lag rather than disguising it as taper.
- [ ] Apply stabilization before spacing and direction; preserve actual sample
  provenance for commit and telemetry.
- [ ] Run `swift test --filter 'BrushDirectionTrackerTests|StrokeStabilizerTests|BrushStrokeGeneratorTests'`.
- [ ] Commit as `feat(input): stabilize path and direction`.

### Task 11: Add Deterministic Timed Emission And Footprint-Aware Spacing

**Files:**

- Create: `Sources/PatternEngine/TimedStrokeEmitter.swift`
- Create: `Sources/PatternEngine/BrushFootprintSpacing.swift`
- Modify: `Sources/PatternEngine/BrushStrokeGenerator.swift`
- Modify: `Sources/PatternEngine/BrushModel/LogicalDabBatch.swift`
- Modify: `Sources/PatternEngine/BrushModel/BrushDefinition.swift`
- Create: `Tests/PatternEngineTests/TimedStrokeEmitterTests.swift`
- Create: `Tests/PatternEngineTests/BrushFootprintSpacingTests.swift`

**Behavior:** A definition may request distance emission, time emission, or the
union of both. Timestamped samples drive time candidates, so stationary
airbrush deposition is replayable. Distance spacing uses the projected tip
support along the local path tangent, including aspect and rotation, rather
than nominal diameter alone.

- [ ] Add deterministic stationary-hold tests at different event batching and
  display rates; identical trace time must yield identical dab ordinals.
- [ ] Add ellipse/chisel spacing tests at 0, 45, and 90 degrees with no gaps or
  runaway density.
- [ ] Define `BrushEmissionDefinition` with bounded `minimumInterval` and
  `minimumDistanceFraction`; reject unbounded emission rates at compile time.
- [ ] Carry tangent/support metadata in `LogicalDabBatch` so projection applies
  whole-frame transforms after logical generation.
- [ ] Run `swift test --filter 'TimedStrokeEmitterTests|BrushFootprintSpacingTests|BrushStrokeGeneratorTests'`.
- [ ] Commit as `feat(brush): add coherent dab emission`.

**Stage C exit:** Speed, pressure, tilt, direction, time, and spacing compose in
a deterministic schema-v2 program; zoom/batching/display rate do not alter
committed output; broad tips turn without angle discontinuities.

---

## Stage D — Establish Correct Color And Bounded Paint Surfaces

### Task 12: Implement A Linear-Light Color Contract

**Files:**

- Create: `Sources/PatternEngine/Color/DocumentColor.swift`
- Create: `Sources/MetalRenderer/Color/DocumentColorPipeline.swift`
- Modify: `App/PatternSpike/Panels/EditorTopBar.swift`
- Modify: `Sources/MetalRenderer/Shaders.metal`
- Create: `Tests/PatternEngineTests/DocumentColorTests.swift`
- Create: `Tests/MetalRendererTests/DocumentColorPipelineTests.swift`

**Behavior:** UI and archive colors are encoded sRGB. `DocumentColorPipeline`
converts them once into premultiplied linear sRGB. Deposition, accumulation,
erase coverage, and layer blend equations operate in linear values. Display
and PNG export convert back to encoded sRGB exactly once. Alpha is never gamma
encoded.

- [ ] Add independent CPU reference vectors for sRGB transfer boundaries,
  50% source-over, low-flow repeated buildup, erase, transparent colors, and
  round-trip error.
- [ ] Add a shader differential test with absolute linear-channel error at most
  `2e-3` for half-float working surfaces.
- [ ] Implement the typed conversion functions and shader reference kernels,
  but do not switch production paint surfaces in this task. The atomic switch
  occurs with sparse allocation in Task 13 so no intermediate commit creates
  full-canvas RGBA16F front/scratch textures.
- [ ] Change display texture/view formats to `.bgra8Unorm_srgb` or explicit
  output encode where that format cannot be used.
- [ ] Audit every `InkColor`/`CGColor`/texture boundary and label values as
  encoded, linear-unpremultiplied, or linear-premultiplied in types.
- [ ] Run `swift test --filter 'DocumentColorTests|DocumentColorPipelineTests|DepositionReferenceTests|DepositionShaderSourceTests'`.
- [ ] Commit as `feat(color): blend paint in linear sRGB`.

### Task 13: Replace Full-Canvas Working Textures With Sparse Tiles

**Files:**

- Create: `Sources/MetalRenderer/Raster/PaintTileDescriptor.swift`
- Create: `Sources/MetalRenderer/Raster/PaintTileStore.swift`
- Create: `Sources/MetalRenderer/Raster/PaintTileResidency.swift`
- Create: `Sources/MetalRenderer/Raster/TiledRasterSurface.swift`
- Modify: `Sources/MetalRenderer/CanonicalRaster.swift`
- Modify: `Sources/MetalRenderer/Shaders.metal`
- Modify: `Sources/MetalRenderer/StrokeRuntime/PredictionOverlay.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Create: `Tests/MetalRendererTests/TiledRasterSurfaceTests.swift`
- Create: `Tests/MetalRendererTests/PaintTileResidencyTests.swift`

**Behavior:** Tiles are 256 x 256 `rgba16Float` private textures with a one-tile
dirty ownership unit. Empty tiles are represented without a texture. Active,
dirty, history-before, and visible tiles are pinned; clean offscreen tiles are
evictable after their backing snapshot exists. The budget is
`min(256 MiB, max(64 MiB, device.recommendedMaxWorkingSetSize / 8))` where the
device reports a nonzero recommendation, otherwise 128 MiB on macOS and 64 MiB
on iOS.

- [ ] Add allocation tests proving a one-dab 4096 canvas allocates only touched
  tiles, not a 4096 x 4096 RGBA16F texture.
- [ ] Add edge/halo tests for dabs and erasers crossing 2 and 4 tile corners.
- [ ] Add deterministic LRU tests, pinning tests, memory-pressure eviction, and
  typed allocation-failure rollback.
- [ ] Make commit transactions capture before/after tile snapshots while still
  producing one region-history command per stroke.
- [ ] Atomically activate `DocumentColorPipeline` and `rgba16Float` for every
  paint-bearing canonical/live/prediction/scratch tile; delete the legacy
  encoded-BGRA8 paint blend path in the same commit.
- [ ] Add differential raster tests between the old full surface and tiled
  surface for existing dry scenes before removing the old allocation path.
- [ ] Run `swift test --filter 'TiledRasterSurfaceTests|PaintTileResidencyTests|RasterRevisionStoreTests|DepositionRendererTests'`.
- [ ] Commit as `refactor(raster): use sparse paint tiles`.

### Task 14: Add A Linear Tile-Based Layer Compositor

**Files:**

- Create: `Sources/EditorCore/Layers/LayerStack.swift`
- Create: `Sources/MetalRenderer/Compositing/LayerCompositor.swift`
- Create: `Sources/MetalRenderer/Compositing/LayerBlendPipeline.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/PatternFile/PatternProjectArchive.swift`
- Modify: `App/PatternSpike/Persistence/PatternProjectBridge.swift`
- Create: `Tests/EditorCoreTests/LayerStackTests.swift`
- Create: `Tests/MetalRendererTests/LayerCompositorTests.swift`
- Modify: `Tests/PatternFileTests/PatternRasterExportCodecTests.swift`

**Behavior:** The first production layer model supports at most eight layers,
one active layer, visibility, opacity, lock, reorder, and `normal`, `multiply`,
and `screen` blend modes. Paint mutates only the active unlocked layer.
Composition reads dirty visible tiles in deterministic layer order and uses
linear premultiplied equations. Project persistence stores nonempty RGBA16F
tiles with IDs, bounds, byte order, semantic hash, and revision; PNG remains an
encoded-sRGB interchange/export format.

- [ ] Add pure model tests for add/delete/reorder/visibility/opacity/lock and
  active-layer fallback.
- [ ] Add independent CPU/GPU blend differentials and transparent-edge tests.
- [ ] Add project v1 import into a single v2 layer and deterministic v2 archive
  round trips.
- [ ] Add a 2048 x 2048 eight-layer residency test and fail if live GPU tile
  bytes exceed the configured budget.
- [ ] Verify undo/redo targets the original layer ID after reorder.
- [ ] Run `swift test --filter 'LayerStackTests|LayerCompositorTests|PatternRasterExportCodecTests|PatternProjectBridgeTests'`.
- [ ] Commit as `feat(layers): add bounded linear compositor`.

**Stage D exit:** Low-flow buildup and blending match independent linear-light
references, high precision no longer requires full-canvas per-layer textures,
and eight-layer composition respects memory, history, export, and ordering.

---

## Stage E — Make Tip Resources And Backends Explicit

### Task 15: Compile Tip Support, Mips, And Reusable Procedural Masks

**Files:**

- Create: `Sources/PatternEngine/BrushModel/BrushTipSupport.swift`
- Modify: `Sources/MetalRenderer/BrushCompiler/BrushAssetDecoder.swift`
- Modify: `Sources/MetalRenderer/BrushCompiler/CompiledBrush.swift`
- Create: `Sources/MetalRenderer/BrushCompiler/BrushMaskCache.swift`
- Modify: `Sources/MetalRenderer/BrushCompiler/BrushResourceResidency.swift`
- Modify: `Sources/MetalRenderer/Deposition/DepositionEncoder.swift`
- Modify: `Package.swift`
- Create: `Tests/MetalRendererTests/BrushMaskCacheTests.swift`
- Modify: `Tests/MetalRendererTests/BrushCompilerTests.swift`

**Behavior:** Textured tips compile lossless source, mip pyramid, normalized
alpha-support bounds, stable simplified cursor contour, and padding metadata.
Round/ellipse/chisel procedural tips use analytic shader coverage rather than
prebaked 64/128/256 circles. The cache key includes semantic tip hash,
quantized size/aspect/rotation/hardness/subpixel phase, and precision.

- [ ] Add malformed/missing resource and support-bound tests.
- [ ] Add mip-selection tests from projected footprint and high-zoom edge tests.
- [ ] Add cache hit/miss/eviction metrics and prove warm drawing performs no
  image decode, upload, or pipeline creation.
- [ ] Do not add universal border padding; only asset-specific support metadata
  demonstrated by a failing clipping test may request padding.
- [ ] Run `swift test --filter 'BrushMaskCacheTests|BrushCompilerTests|DepositionStampInstanceTests'`.
- [ ] Commit as `perf(brush): compile reusable tip support`.

### Task 16: Derive A Truthful Cursor From The Evaluated Tip

**Files:**

- Create: `Sources/PatternEngine/BrushCursorDescriptor.swift`
- Modify: `Sources/MetalRenderer/BrushCompiler/CompiledBrush.swift`
- Modify: `App/PatternSpike/Canvas/InteractiveMetalView.swift`
- Modify: `App/PatternSpike/Canvas/MetalCanvas.swift`
- Modify: `Package.swift`
- Create: `Tests/PatternEngineTests/BrushCursorDescriptorTests.swift`
- Create: `App/Tests/BrushCursorIntegrationTests.swift`

**Behavior:** The cursor uses cached tip support plus current size, neutral hover
pressure, aspect, deformation, tilt/azimuth, brush rotation, and viewport
scale. Circular tips show a circle; broad tips show the transformed contour;
textured/scattered tips show a stable conservative core/envelope. The cursor
path does not read texture bytes or allocate per pointer move.

- [ ] Add pure transform tests for circle, ellipse, chisel, rotation, reflection,
  zoom, backing scale, and missing pressure.
- [ ] Add controlled single-dab raster tests requiring cursor/support IoU at
  least 0.85 and maximum support-edge error at most 1.5 logical pixels.
- [ ] Route hover and brush-size changes through the descriptor immediately.
- [ ] Run `swift test --filter 'BrushCursorDescriptorTests|BrushCursorIntegrationTests|BrushCorrectiveFunctionalTests'`.
- [ ] Commit as `fix(cursor): show evaluated brush footprint`.

### Task 17: Install A Compile-Time Backend Registry

**Files:**

- Create: `Sources/MetalRenderer/BrushBackend/BrushBackendRegistry.swift`
- Create: `Sources/MetalRenderer/BrushBackend/BrushBackendCompiler.swift`
- Modify: `Sources/MetalRenderer/BrushCompiler/BrushCompiler.swift`
- Modify: `Sources/MetalRenderer/BrushCompiler/CompiledBrush.swift`
- Modify: `Sources/MetalRenderer/Deposition/DepositionPipelineLibrary.swift`
- Create: `Tests/MetalRendererTests/BrushBackendRegistryTests.swift`
- Modify: `Tests/MetalRendererTests/BrushCompilerTests.swift`

**Behavior:** The registry is an immutable sorted table created at app startup.
It maps `(BrushBackendKind, schemaVersion)` to a compiler and encoder family.
Unknown kinds or versions fail package activation with a typed diagnostic.
No runtime library loading, class-name lookup, or executable package code is
allowed. Preset catalog aliases are data migration and remain separate.

- [ ] Add duplicate, unknown, version mismatch, deterministic-order, and
  backend-capability tests.
- [ ] Register deposition and continuous-ribbon capabilities; the latter may
  remain internal until a brush proves it necessary.
- [ ] Remove `usesDestinationSampling` from the deposition function-constant
  path because it is not actually wired; represent it only in a compiled
  canvas-interaction backend contract.
- [ ] Keep `secondaryColorMix` as a semantic value but reject nonzero use until
  a backend declares and implements the required color-source capability.
- [ ] Run `swift test --filter 'BrushBackendRegistryTests|BrushCompilerTests|DepositionPipelineLibraryTests'`.
- [ ] Commit as `refactor(brush): register static render backends`.

### Task 18: Add Bounded Native Composite Dry Brushes

**Files:**

- Create: `Sources/PatternEngine/BrushModel/BrushComponentDefinition.swift`
- Modify: `Sources/PatternEngine/BrushModel/BrushDefinition.swift`
- Modify: `Sources/PatternEngine/BrushModel/BrushProgram.swift`
- Create: `Sources/PatternEngine/CompositeBrushStrokeGenerator.swift`
- Modify: `Sources/MetalRenderer/BrushCompiler/CompiledBrush.swift`
- Modify: `Sources/MetalRenderer/Deposition/DepositionEncoder.swift`
- Modify: `Sources/BrushFormat/BrushContentHash.swift`
- Add focused PatternEngine, BrushFormat, and MetalRenderer tests

**Behavior:** Native schema version 3 supports one or two ordered dry brush
components. Each component retains independent coverage, placement, dynamics,
color, material, taper, resources, and deterministic random namespace. This is
different from the existing `dualShape` and `dualGrain` layers, which combine
resources inside one dab and cannot represent independent sub-brush spacing or
size. Schema version 2 remains the ordered multi-sensor format introduced by
Task 9; version-1 and version-2 definitions decode as a single canonical
component.

- [ ] Add schema-v1/v2 migration and prove established single-component package,
  digest, dynamics, and raster anchors remain compatible.
- [ ] Drive component generators from the same authoritative input stream while
  preserving independent resampling and append-only output; never replay the
  retained stroke to produce the secondary component.
- [ ] Key randomness by stroke/sample identity, component ordinal,
  component-dab ordinal, and channel so collection order cannot change pixels.
- [ ] Carry component identity through compile, resource selection, batching,
  deposition, erase, bounds, cursor support, history, tiling, and radial
  transforms.
- [ ] Enforce a maximum of two components in this schema version and include
  component expansion in frame-work, resident-memory, and dab-count budgets.
- [ ] Characterize the initial dry composition mode independently. Unknown or
  unsupported required modes fail activation instead of silently flattening.
- [ ] Add independent-spacing/dynamics, component-order, random-isolation,
  erase, cursor-union, symmetry, empty-output, budget, and performance tests.
- [ ] Run `swift test` plus existing single-component raster anchors.
- [ ] Commit as `feat(brush): add composite dry components`.

### Task 19: Separate Diagnostics From Production Rendering

**Files:**

- Modify: `Package.swift`
- Modify: `App/project.yml`
- Move: `Sources/MetalRenderer/Capture/` to
  `Sources/MetalRendererDiagnostics/Capture/`
- Move: `Sources/MetalRenderer/Deposition/DepositionReference.swift` to
  `Sources/MetalRendererDiagnostics/Reference/DepositionReference.swift`
- Modify: `App/PatternSpike/Harness/HarnessLaunch.swift`
- Modify: `Tests/MetalRendererTests/`
- Create: `Tests/MetalRendererDiagnosticsTests/DiagnosticsBoundaryTests.swift`

**Behavior:** `MetalRenderer` contains production rendering and cheap runtime
telemetry only. Harness runners, PNG/readback evidence, CPU reference raster,
and validators live in `MetalRendererDiagnostics`, which depends on
`MetalRenderer`; the dependency never points back. Debug/harness app builds
link diagnostics, release product builds do not.

- [ ] Add package boundary tests/build checks proving the release app does not
  link the diagnostics target.
- [ ] Move files mechanically first, then expose the smallest public snapshot
  API needed by diagnostics; do not make renderer internals broadly public.
- [ ] Update every evidence executable/test dependency and XcodeGen source path.
- [ ] Run `swift test` and both Debug and Release macOS app builds.
- [ ] Commit as `refactor(render): isolate diagnostics target`.

**Stage E exit:** Warm brushes reuse compiled resources, the cursor matches tip
support, backend choice is typed and static, bounded composite dry brushes
preserve independent component behavior without replay, false
destination-sampling claims are gone, and production rendering no longer
carries the evidence harness.

---

## Stage F — Rebuild The Four Brushes One At A Time

Implement each brush as an independently measurable candidate, but do not wait
for manual review between brushes. Focused tests run during each task; the
exhaustive cross-family dry-brush checkpoint runs after all four candidates are
ready. A brush may enter the product catalog only after the final manual round
explicitly passes it. Physical iPad/Wacom status remains pending.

### Task 20: Rebuild Technical Ink

**Files:**

- Modify: `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift`
- Add assets under: `Sources/BrushFormat/Resources/Professional/TechnicalInk/`
- Modify: `Tests/EditorCoreTests/ProfessionalBrushDynamicsTests.swift`
- Modify: `Tests/MetalRendererTests/BrushCorrectiveFunctionalTests.swift`
- Modify: `App/PatternSpike/Harness/Scenes/professional-technical-ink.json`
- Modify: `App/PatternSpike/BrushLab/BrushLabManualCard.swift`

- [ ] Author a neutral anti-aliased ink tip and provenance; do not reuse the
  current fixture as the visual target.
- [ ] Use append-only deposition, causal cap termination, short weighted path
  stabilization, and pressure-driven size/flow with explicit mouse neutral.
- [ ] Require neutral straight width to be 0.80...1.10 of nominal diameter,
  endpoint retreat at most 1 logical pixel, no centerline gaps, and cursor IoU
  at least 0.90.
- [ ] Require CPU preparation p95 below 2 ms, event-to-submit p95 below 8 ms for
  the 60 Hz software trace, missed fraction at most 1%, zero actual replay, and
  no growing backlog.
- [ ] Export the Brush Lab edge/join, taper, pressure, erase, responsiveness,
  and prolonged-drawing candidate artifacts with manual status still pending.
- [ ] Run the focused tests and production app trace; do not wait for manual
  validation before starting the next brush.
- [ ] Commit as `feat(brush): rebuild technical ink`.

### Task 21: Rebuild Graphite Pencil

**Files:**

- Modify: `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift`
- Add assets under: `Sources/BrushFormat/Resources/Professional/Graphite/`
- Modify: `Tests/EditorCoreTests/ProfessionalBrushDynamicsTests.swift`
- Modify: `Tests/MetalRendererTests/BrushCorrectiveFunctionalTests.swift`
- Modify: `App/PatternSpike/Harness/Scenes/professional-graphite-pencil.json`

- [ ] Author at least one irregular tip and one independent paper grain with
  lossless sources, mips, support bounds, scale, and provenance.
- [ ] Separate pressure effects on coverage, size, and grain strength; use
  direction/tilt only where the authored physical model justifies them.
- [ ] Require the cursor to match measured visible support within 1.5 logical
  pixels, one neutral pass to remain visibly textured, and three repeated
  passes to increase median darkness by at least 20% without one-pass clipping.
- [ ] Check grain continuity through turns, zoom, periodic seams, and radial
  transforms; reject screen-locked or swimming texture.
- [ ] Pass the same runtime thresholds as Technical Ink at its declared nominal
  workload and export Graphite manual candidates as pending.
- [ ] Commit as `feat(brush): rebuild graphite pencil`.

### Task 22: Rebuild Natural Charcoal

**Files:**

- Modify: `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift`
- Add assets under: `Sources/BrushFormat/Resources/Professional/Charcoal/`
- Modify: `Tests/EditorCoreTests/ProfessionalBrushDynamicsTests.swift`
- Modify: `Tests/MetalRendererTests/BrushCorrectiveFunctionalTests.swift`
- Modify: `App/PatternSpike/Harness/Scenes/professional-natural-charcoal.json`

- [ ] Complete Tasks 1–6 of
  `docs/superpowers/plans/2026-08-01-authored-procreate-charcoal-corpus.md` so
  the approved `C Charcoal` and `C Charcoal Soft` parent-plus-`Sub01` archives
  yield native composite packages and honest conversion reports before
  calibrating the product preset.
- [ ] Execute focused-plan Task 7 here. Use Laya-owned replacements for the
  absent `Haggard-Oval.png`, `Brush-Preset-Bonobo.png`, and
  `Brush-Artery-Charcoal-Corse.jpg`; derive the grains from the supplied owned
  paper photographs. Do not package or label any absent built-in as exact.
- [ ] Keep the supplied `.brushset` on the offline tooling/test path; the native
  definition and admitted resources are the only inputs to `EditorCore` and
  `MetalRenderer`.
- [ ] Require parent-only, child-only, and combined evidence so both components
  make a useful measurable contribution and retain independent size, spacing,
  dynamics, grain transform, and random streams.
- [ ] At neutral pressure require changed pixels, alpha p50 at least 0.12 inside
  the authored support, alpha p90 at least 0.30, and visible broad-side versus
  edge variation for tilt-capable input.
- [ ] Validate tonal buildup, grain scale, seam continuity, footprint-matched
  erase, mouse fallback, cursor/support agreement, and low/mid/high spatial
  frequency energy. One-pixel tip, zero-grain, disabled-component,
  merged-random-stream, shrunken-support, and seam negative controls must fail.
- [ ] Pass runtime thresholds at nominal and large sizes and export Charcoal
  manual candidates as pending.
- [ ] Commit as `feat(brush): rebuild natural charcoal`.

### Task 23: Rebuild Chisel Marker And Gate The Ribbon Backend

**Files:**

- Modify: `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift`
- Add assets under: `Sources/BrushFormat/Resources/Professional/Chisel/`
- Modify: `Sources/PatternEngine/BrushDirectionTracker.swift`
- Modify: `Tests/MetalRendererTests/BrushCorrectiveFunctionalTests.swift`
- Modify: `App/PatternSpike/Harness/Scenes/professional-chisel-marker.json`
- Conditionally create: `Sources/MetalRenderer/BrushBackend/ContinuousRibbonEncoder.swift`

- [ ] First implement with filtered shortest-angle stamp frames and
  footprint-aware spacing; add fan interpolation only where the turn test shows
  an uncovered wedge.
- [ ] Require zero isolated icicle components, maximum turn protrusion at most
  0.15 nominal diameter, no interior gap wider than 2 logical pixels, and
  consistent broad/edge widths.
- [ ] If automated turn thresholds pass with stamps, keep the stamp backend as
  the candidate; the final manual round may still reopen this decision.
- [ ] If an automated threshold fails, capture the failing raster/metric,
  implement the registered continuous-ribbon backend for Chisel only, and
  rerun the complete deposition/tiling/symmetry/erase/history matrix.
- [ ] Pass nominal and tight-turn performance thresholds and export Chisel
  manual candidates as pending.
- [ ] Commit as `feat(brush): rebuild chisel marker`.

**Stage F exit:** Each brush has authored resources and provenance and passes
its focused functional/performance gate. The exhaustive cross-family dry-brush
checkpoint is green. Manual status remains pending for every candidate and all
four stay out of the product catalog until the final manual round.

---

## Stage G — Integrate, Exercise The Real App, And Publish Honest Evidence

### Task 24: Shrink `GridRenderer` To A Main-Actor Facade

**Files:**

- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Create: `Sources/MetalRenderer/Display/CanvasDisplayCompositor.swift`
- Create: `Sources/MetalRenderer/Transactions/StrokeCommitter.swift`
- Modify: `Sources/MetalRenderer/GridRenderer+Harness.swift`
- Modify: `Tests/MetalRendererTests/DepositionRendererTests.swift`

**Final ownership:** `GridRenderer` owns MTKView/display state, editor-facing
commands, the active coordinator handle, and final composition. It does not own
`BrushStrokeGenerator`, `TransientStrokeBuffer`, retained projected records,
resource decoding, evidence generation, or frame-budget policy.

- [ ] Move display composition and commit/history bridging into the focused
  units after characterization tests are green.
- [ ] Delete the debug old-runtime switch and all unreachable replay-layer
  product code.
- [ ] Prove compile-time ownership by keeping `PatternEngine` independent and
  `MetalRendererDiagnostics -> MetalRenderer` one-way.
- [ ] Run `swift test` and inspect `GridRenderer` for any remaining loop over a
  completed live stroke during input or frame draw.
- [ ] Commit as `refactor(render): finish stroke runtime split`.

### Task 25: Run The Cross-Family Functional Matrix

**Files:**

- Create: `Sources/MetalRendererDiagnostics/Capture/BrushCorrectiveGate.swift`
- Create: `Sources/BrushCorrectiveEvidenceGate/main.swift`
- Modify: `Package.swift`
- Modify: `App/PatternSpike/Harness/HarnessLaunch.swift`
- Create: `Tests/MetalRendererDiagnosticsTests/BrushCorrectiveGateTests.swift`

**Matrix:** taps; slow/fast lines; long curves; circles; 90-degree and repeated
tight turns; reversal; low/neutral/high pressure; tilt/azimuth sweeps; mouse;
1 px/nominal/40 px/large/max size; prediction on/off; plain/periodic/radial;
maximum symmetry; draw/erase; cold/warm/cache churn/memory pressure; 10-second
and accelerated 10-minute runs.

- [ ] Require deterministic canonical pixels across batching, prediction,
  viewport zoom, and display cadence.
- [ ] Require canonical parity across preview/commit, exactly one history
  command, correct undo/redo, and cancel preserving prior pixels.
- [ ] Require no input-path decode/upload/pipeline creation/GPU wait, zero
  append-only actual replay, bounded queue and residency, and no monotonic
  latency growth.
- [ ] Add negative controls that independently fail each gate category.
- [ ] Run `swift test`, then `swift run BrushCorrectiveEvidenceGate`.
- [ ] Commit as `test(brush): add corrective evidence gate`.

### Task 26: Exercise The Production macOS UI And Export Manual Candidates

**Files:**

- Create: `App/UITests/BrushCorrectiveUITests.swift`
- Modify: `App/PatternSpike/Debug/DebugPerformanceHUD.swift`
- Modify: `App/PatternSpike/Debug/DebugPerformanceMonitor.swift`
- Modify: `App/PatternSpike/BrushLab/BrushLabSession.swift`
- Modify: `docs/superpowers/milestones/12-professional-dry-media.md`
- Modify: `docs/superpowers/16-reference-sheet.md`

- [ ] Launch the production app, select every candidate brush, set exact sizes,
  perform straight/curved/long strokes, change tools, erase, undo/redo, clear,
  switch plain/periodic/radial on a clean canvas, and verify controls remain
  responsive while drawing.
- [ ] Capture canvas PNG, screen image, input trace, semantic hash, HUD snapshot,
  and isolated JSONL segment for every test workload.
- [ ] Keep the HUD compact at bottom-right and verify opening it with tilde does
  not steal numeric input focus or alter shortcut routing.
- [ ] Export complete Brush Lab candidate cards and reference artifacts for
  look, feel, texture, joins, pressure, tilt, erase, responsiveness, and
  prolonged use. Leave their result explicitly pending; do not request manual
  validation during Stage G.
- [ ] Build the iPadOS simulator target and run platform-independent app tests;
  record physical Pencil/120 Hz/thermal/memory/Wacom checks as pending.
- [ ] Update milestones with the five-state vocabulary only:
  `engineIntegrated`, `softwarePerformancePassed`, `manualQualityPassed`,
  `physicalProfilePassed`, and `productAccepted`.
- [ ] Commit as `docs(brush): publish corrective evidence status`.

### Task 27: Complete Automated Integration Verification

- [ ] Run `swift test` with normal parallelism, then rerun only documented
  process-global Metal/harness suites with `--no-parallel`.
- [ ] Regenerate Xcode projects and build Debug/Release macOS plus Debug iPadOS
  simulator targets with warnings treated as errors.
- [ ] Run one full 10-second and accelerated 10-minute integration trace;
  compare hashes, p95/p99 latency, memory high-water, and cache behavior. The
  mandatory repeated performance round runs after this stage.
- [ ] Inspect the production app log for input-path allocations, actual replay,
  unbounded queue growth, GPU waits, dropped actual input, and silent fallback.
- [ ] Set `engineIntegrated` only when every Stage G automated gate is green.
  Keep every candidate laboratory-only while `manualQualityPassed` is pending.
- [ ] Do not mark `softwarePerformancePassed`, `physicalProfilePassed`,
  `realtime120`, or `productAccepted` here.
- [ ] Commit as `feat(brush): complete automated integration`.

**Stage G exit:** All implementation stages, cross-family functional checks,
production-app automation, and builds are green. Candidate manual cards are
complete but pending. No brush is product-admitted yet.

---

## Post-Stage-G Acceptance Round

### Task 28: Run Full Performance, Repair Failures, Then Perform Manual Review

**Files:**

- Modify as failures require: production code and focused regression tests
- Modify: `App/PatternSpike/BrushLab/BrushLabSession.swift`
- Modify: `docs/superpowers/milestones/12-professional-dry-media.md`
- Modify: `docs/superpowers/16-reference-sheet.md`
- Persist generated artifacts under: `.build/brush-corrective-acceptance/`

- [ ] Run the complete cold/warm, nominal/large/max-size,
  plain/periodic/radial, maximum-symmetry, cache-churn, memory-pressure,
  10-second, and accelerated 10-minute matrix three times for all four brushes.
- [ ] Compare FPS, frame p95/p99, event-to-submit p95/p99, CPU preparation, GPU
  duration, missed-frame fraction, actual/predicted queue depth, backlog
  high-water, memory high-water, cache hits/misses, input-path work, and
  canonical hashes across runs.
- [ ] Treat any visible-output, cursor, endpoint, texture, continuity, control,
  determinism, backlog, latency, memory, or silent-fallback failure as an
  implementation defect. Fix it, add a focused regression, and rerun the
  affected cluster. Rerun the full matrix after any performance-path change.
- [ ] Set `softwarePerformancePassed` only when all three complete runs pass and
  HUD values agree with persisted JSONL summaries.
- [ ] Present the complete candidate set for one user manual round covering
  look, feel, texture, joins, taper, pressure, tilt, buildup, erase, symmetry,
  responsiveness, and prolonged drawing. Record explicit pass/fail notes.
- [ ] Fix every manual failure. Rerun its functional cluster and, when runtime
  or performance code changed, the complete performance matrix. Repeat manual
  validation only for affected cards.
- [ ] Admit only brushes with green automated gates and explicit manual passes
  into `EditorBrushCatalog.drawEntries`; keep any other brush laboratory-only.
- [ ] Keep iPad/Pencil/120 Hz/thermal/memory/Wacom evidence pending. Do not set
  `physicalProfilePassed`, `realtime120`, or `productAccepted` without qualifying
  hardware evidence.
- [ ] Commit as `feat(brush): complete corrective acceptance`.

## Engineering Completion Criteria

The corrective program is engineering-complete only when all automated stages
and the post-Stage-G performance round are green. Product brush admission also
requires the final manual cards to pass. The criteria are:

- no product dry brush performs retained-body replay on actual input;
- long-stroke per-event CPU work is flat within measurement noise;
- the main actor does not run stroke generation, projection, or live-surface
  encoding;
- prediction cannot alter committed pixels;
- pointer-up does not visibly retreat the ordinary brush endpoint;
- cursor/support metrics pass for every admitted brush;
- speed, multi-sensor dynamics, direction, timed emission, and anisotropic
  spacing have deterministic tests;
- color and layer equations match independent linear-light references;
- RGBA16F paint storage is sparse and respects its byte budget;
- diagnostics are absent from the Release production renderer dependency graph;
- Technical Ink, Graphite, Charcoal, and Chisel each pass their own functional
  and performance gates; each also needs an explicit manual pass before product
  admission;
- clear, tool switching, erasing, tiling controls, numeric input, HUD, undo,
  redo, and mode switching remain responsive in the real macOS app;
- missing iPad/Wacom evidence is represented as pending, not passed.

## Explicit Non-Goals Of This Corrective Program

- runtime import or execution of Procreate brush data/code; offline conversion
  of the explicitly approved authored charcoal corpus is in scope;
- a polished public Brush Studio editor;
- arbitrary runtime plugins;
- copying Krita implementation code;
- claiming final wet paint behavior—the plan creates its typed backend boundary
  but wet transport/mixing needs its own measured design and implementation;
- increasing radial ray count after a radial document has paint;
- changing the established top-left crop/fill behavior;
- changing logical-dab-before-symmetry ordering;
- declaring 120 Hz or iPad thermal success from macOS, simulator, or virtual
  evidence.

## Plan Self-Review Checklist

- [ ] Every confirmed corrective finding maps to a task or an explicit non-goal.
- [ ] No archived external claim is used without a repository or primary-source
  confirmation.
- [ ] Every behavior-changing task begins with a failing test or measurable
  functional assertion.
- [ ] Every new public type has module ownership, serialization implications,
  and concurrency semantics stated.
- [ ] Every stage has a runnable exit gate and a small commit boundary.
- [ ] No task contains unfinished implementation markers, stub code, or a
  fabricated physical result.
- [ ] A final reviewer checks schema-v1 compatibility, v2 dynamics migration,
  v3 composite semantic hashing, PatternFile migration, strict concurrency,
  color transfer count, memory budget, and product status language before
  execution begins.
