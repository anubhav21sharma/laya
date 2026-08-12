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

**Execution status (2026-08-13):** Stages A through G and the automated
performance/repair portion of Task 28 are complete. The persisted three-pass,
24-trace matrix sets `engineIntegrated=true` and
`softwarePerformancePassed=true`. That matrix predates the final compositor
completion-poll lifecycle repair. Focused final-source lifecycle and hosted
production-canvas tests pass, but a fresh matrix attempt on the current Apple
Paravirtual GPU host stops at its first strict timing gate (9.13 ms
event-to-submit p95 versus the required value below 8 ms). A controlled
pre-repair build measures 9.21 ms on the same host, so the lifecycle repair is
not the regression. Final-source performance requalification remains pending
an eligible run environment; the earlier matrix remains historical accepted
evidence rather than a fresh claim about this host.
Manual review of 68 candidate cards, any fixes it identifies, catalog
admission, and qualifying iPad/Pencil/120 Hz/thermal/memory/Wacom evidence
remain pending; therefore `manualQualityPassed=false`,
`physicalProfilePassed=false`, and `productAccepted=false`. The Xcode-hosted UI
route now executes after the user approved macOS UI Automation. Its exact
`StageDAppRouteUITests` gate exercised all 29 controls/shortcuts/persistence
routes repeatedly with one test passed, zero failures, three passing scenario
rows, real schema-4 save/open replacement, and a valid PNG export. The
acceptance wrapper's separate locally signed `build-for-testing` and
`test-without-building` roots passed in 198.722 seconds; the definitive
pre-commit final-source run passed in 156.435 seconds, and exact pushed
implementation commits `1810dce` and `e8756ee` passed in 145.050 and 158.444
seconds without another authorization prompt. A fresh `e8756ee` aggregate
passed 656 focused tests, all 2,206 broad tests in 120 suites, all product
builds, and its runtime/allocation probes before final packaging exposed three
producer/consumer validation mismatches. The corrected validator now accepts
the captured 12-row package with bounded allocation and positive one-shot cache
miss evidence; its affected 81-test matrix passes. That interrupted attempt
does not count, so two fresh clean-commit aggregate runs remain pending; direct
signed production-UI replay and the hosted non-XCTest regression are green.

The original task-level commit checkpoints are represented by existing
mainline history plus the authorized consolidated corrective-program closeout
commit. They are not retroactively rewritten into artificial historical
commits.

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

## Universal Stage Delivery Protocol

The Stage B acceptance cycle exposed that a large task can hide state-machine,
platform, and performance defects until late integration. Every remaining stage
therefore uses the following protocol:

1. Replan the stage just in time from the current code and approved specs.
2. Split pure semantic components from schema ownership and production wiring.
3. Keep one schema owner and enumerate every lifecycle transition before edits.
4. Use focused red/green tests while implementing. Run production-path
   functional and performance tests at meaningful vertical-slice boundaries,
   not after every internal edit.
5. Review meaningful task or slice boundaries once their focused evidence is
   complete. Do not restart broad review cycles after minor follow-up edits.
6. Add allocation/bounded-work evidence in the task that creates a hot path.
7. Finish with a clustered stage acceptance covering correctness, lifecycle,
   production routes, sustained performance, failure recovery, and fresh review.
8. Do not declare delivery or wait for manual review until the automated stage
   gate is complete. Physical/manual evidence remains a later admission gate.

Stage C's expanded protocol and executable steps are defined in
[`2026-08-02-stage-c-physical-input-dynamics.md`](2026-08-02-stage-c-physical-input-dynamics.md).
Stages D through G receive equivalent just-in-time preflights before execution.

## Native Current-Only And Boundary-Validation Amendment

The project owner removed every Laya-native backward-compatibility requirement
on 2026-08-10. The binding design and dependency-ordered deletion plan are
[`2026-08-10-native-current-only-validation-design.md`](../specs/2026-08-10-native-current-only-validation-design.md)
and
[`2026-08-10-native-current-only-cleanup.md`](2026-08-10-native-current-only-cleanup.md).
They override conflicting native migration, alias, legacy execution, and
compatibility-test requirements below.

- Laya-native projects, brushes, packages, renderer/harness formats, and other
  pre-release schemas accept exactly the current version. Older and future
  versions fail clearly; no native migration adapters are added or retained.
- External imports such as Procreate remain product features. Their untrusted
  parsers stay defensive and emit the current trusted Laya-native model.
- Validate strongly at untrusted file/import, checked arithmetic/memory/Metal,
  transactional publication, and GPU/resource-ownership boundaries. Internal
  layers consume validated immutable types or unforgeable capabilities instead
  of repeating the same checks.
- Remove brittle source-text gates, implausible-state hooks, duplicate invariant
  tests, and compatibility cleanup machinery after stronger construction and
  ownership guarantees supersede them. Functional correctness, visual quality,
  performance, cancellation safety, data integrity, and leak-free ownership
  remain non-negotiable.

## Locked Technical Decisions

1. **Authoritative deposition is append-only.** Retained-tail work exists only
   as an explicitly typed, bounded current correction/prediction mechanism. It
   is not a persisted legacy mode and cannot select an old execution path.
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
6. **Dynamics are ordered programs.** The exact current native definition
   schema accepts up to four ordered sensor terms. Older native schemas fail
   activation; foreign converters emit the current program directly.
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

**Behavior:** Keep the four definitions available only to Brush Lab with the
five-field candidate status. Remove them from `EditorBrushCatalog.drawEntries`
and restore the vetted anchor ink as `defaultDraw`. Persisted professional IDs
must resolve to a laboratory-only entry with a clear message instead of
silently selecting a different brush.

- [x] Add catalog tests proving none of the four IDs is product-selectable,
  all remain resolvable in Brush Lab, and a persisted ID reports laboratory
  status.
- [x] Add the `engineIntegrated`, `softwarePerformancePassed`,
  `manualQualityPassed`, `physicalProfilePassed`, and `productAccepted` fields
  and route all four entries through them.
- [x] Change milestone language from completed/realtime120 to corrective work
  required; retain old counts only as historical evidence.
- [x] Run `swift test --filter 'ProfessionalBrushCatalogTests|BrushLabSessionTests'`.
- [x] Mainline commit coverage complete (planned checkpoint: `fix(brush): revoke broken preset acceptance`).

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

- [x] Check in timestamped direct traces for a 10-second Technical Ink line, a
  fast-release ink stroke, 40 px Graphite, neutral-pressure Charcoal, and a
  90-degree plus circular Chisel turn.
- [x] Implement measurements from readback pixels using independent scalar CPU
  code; do not call brush dynamics or shader helpers to compute expected data.
- [x] Add assertions that currently fail for retained-body replay, endpoint
  retreat, Graphite cursor/support mismatch, Charcoal visibility, and Chisel
  protrusions.
- [x] Preserve current rasters under `.build/brush-corrective-baseline/` as
  failure evidence, never under an approved golden directory.
- [x] Run `swift test --filter 'BrushCorrectiveFunctionalTests|ProfessionalStrokeTraceTests'`
  and record the expected failures in the task report.
- [x] Mainline commit coverage complete (planned checkpoint: `test(brush): freeze reported functional failures`).

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

- [x] Write aggregation tests using a deterministic synthetic timestamp source.
- [x] Add begin/end segment markers so a user session can be isolated from logs.
- [x] Add a 10-second and accelerated 10-minute production-renderer trace.
- [x] Fail the software gate when actual replay is nonzero for an append-only
  brush, backlog grows monotonically, or event-to-submit misses exceed 1%.
- [x] Run `swift test --filter 'StrokeRuntimeTelemetryTests|DebugPerformanceMonitorTests|BenchmarkRecordTests'`.
- [x] Mainline commit coverage complete (planned checkpoint: `feat(perf): measure live stroke pipeline`).

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

**Behavior:** Current-schema dry brushes use `.cap`, `.pressureRelease(maximumWorldLength:)`,
or `.boundedCorrection(maximumSamples:maximumWorldLength:maximumDabs:)`.
`.cap` and `.pressureRelease` never reevaluate an already deposited ordinal.
Obsolete native termination encodings are rejected and cannot select an old
renderer path.

- [x] Add red tests asserting pointer-up cannot change body dabs, endpoint
  retreat is at most 1 logical pixel for `.cap`, and correction limits reject
  excess samples, distance, or dabs.
- [x] Introduce `BrushTerminationDefinition` and compile it into an immutable
  `BrushTerminationProgram`.
- [x] Delete the product-path call that reevaluates the complete stroke after
  total length becomes known.
- [x] Record the required producer inventory and typed old-version rejection;
  physical native-v1 deletion occurs at Task 14A after Stage D so it does not
  overlap the atomic renderer cutover.
- [x] Run `swift test --filter 'Brush(Definition|DynamicsEngine|TerminationEvaluator)Tests'`.
- [x] Mainline commit coverage complete (planned checkpoint: `fix(brush): make stroke termination causal`).

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

- [x] Add tests for 1, 10, 1,000, and 100,000 input events proving each ordinal
  is emitted and submitted once and per-event returned work does not grow with
  stroke age.
- [x] Add batching-invariance tests: one batch versus arbitrary subdivisions
  must produce identical ordered authoritative dabs and canonical pixels.
- [x] Extract a sendable immutable `CompiledBrushRenderState` from the
  main-actor `CompiledBrush`; isolate immutable Metal references in one audited
  `@unchecked Sendable` resource holder if the SDK lacks conformances.
- [x] Route one current native ink brush through the coordinator. Use any
  temporary A/B oracle only within the cutover test, then delete the old path
  and selector in the same accepted slice.
- [x] Remove ordinary actual-input calls to `rebuildReplayLayer` and equivalent
  retained-body encoding.
- [x] Run `swift test --filter 'StrokeRenderCoordinatorTests|TransientStrokeBufferTests|DepositionMetamorphicTests'`.
- [x] Mainline commit coverage complete (planned checkpoint: `refactor(render): append authoritative stroke work`).

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

- [x] Write tests proving prediction on/off and arbitrary replacement cadence
  produce byte-identical committed output.
- [x] Set caps to 64 normalized samples, 512 logical dabs, and the frame
  profile's predicted-instance budget; exceeding them truncates prediction
  only and records overload.
- [x] Implement tile-local clear/rebuild for the prediction overlay.
- [x] Ensure pointer-up discards prediction before draining final actual work.
- [x] Run `swift test --filter 'PredictionOverlayTests|DepositionMetamorphicTests|DepositionRendererTests'`.
- [x] Mainline commit coverage complete (planned checkpoint: `feat(render): isolate prediction overlay`).

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
- [x] Mainline commit coverage complete (planned checkpoint: `perf(render): move stroke preparation off main`).

**Stage B exit:** Task 5A's renderer event dispatcher is independently clean;
long strokes have O(new work) CPU behavior, zero actual replay, bounded memory
and queues, isolated prediction, causal endpoints, and the existing
preview/commit/cancel/history/symmetry matrix passes.

Accepted on 2026-08-02. See
[`2026-08-02-stage-b-acceptance.md`](../reports/2026-08-02-stage-b-acceptance.md).

---

## Stage C — Make Input, Dynamics, Direction, And Spacing Physically Coherent

The original four tasks were too broad and left schema ownership, filter math,
corner semantics, candidate ordering, and scheduler resumption under-specified.
They are superseded by the C0 baseline freeze plus thirteen
sequential implementation/acceptance tasks in
[`2026-08-02-stage-c-physical-input-dynamics.md`](2026-08-02-stage-c-physical-input-dynamics.md).

**Stage C exit:** C13 proved deterministic current-schema speed, sensor,
stabilization, direction, corner, time, and footprint semantics;
production scheduler lifecycle correctness; bounded work and allocations; a
10-minute sustained trace; the broad regression baseline; and a fresh review
with no unresolved Critical or Important issue.

---

## Stage D — Establish Correct Color And Bounded Paint Surfaces

The three original tasks below define the approved Stage D outcome, but their
file inventory predates the Stage B off-main surface runtime and the accepted
Stage C lifecycle. They are superseded for execution by the just-in-time
decomposition in
[`2026-08-04-stage-d-color-sparse-surfaces.md`](2026-08-04-stage-d-color-sparse-surfaces.md).
The Stage D exit and every program-wide constraint in this document remain
binding.

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

- [x] Add independent CPU reference vectors for sRGB transfer boundaries,
  50% source-over, low-flow repeated buildup, erase, transparent colors, and
  round-trip error.
- [x] Add a shader differential test with absolute linear-channel error at most
  `2e-3` for half-float working surfaces.
- [x] Implement the typed conversion functions and shader reference kernels,
  but do not switch production paint surfaces in this task. The atomic switch
  occurs with sparse allocation in Task 13 so no intermediate commit creates
  full-canvas RGBA16F front/scratch textures.
- [x] Change display texture/view formats to `.bgra8Unorm_srgb` or explicit
  output encode where that format cannot be used.
- [x] Audit every `InkColor`/`CGColor`/texture boundary and label values as
  encoded, linear-unpremultiplied, or linear-premultiplied in types.
- [x] Run `swift test --filter 'DocumentColorTests|DocumentColorPipelineTests|DepositionReferenceTests|DepositionShaderSourceTests'`.
- [x] Mainline commit coverage complete (planned checkpoint: `feat(color): blend paint in linear sRGB`).

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

- [x] Add allocation tests proving a one-dab 4096 canvas allocates only touched
  tiles, not a 4096 x 4096 RGBA16F texture.
- [x] Add edge/halo tests for dabs and erasers crossing 2 and 4 tile corners.
- [x] Add deterministic LRU tests, pinning tests, memory-pressure eviction, and
  typed allocation-failure rollback.
- [x] Make commit transactions capture before/after tile snapshots while still
  producing one region-history command per stroke.
- [x] Atomically activate `DocumentColorPipeline` and `rgba16Float` for every
  paint-bearing canonical/live/prediction/scratch tile; delete the legacy
  encoded-BGRA8 paint blend path in the same commit.
- [x] Add differential raster tests between the old full surface and tiled
  surface for existing dry scenes before removing the old allocation path.
- [x] Run `swift test --filter 'TiledRasterSurfaceTests|PaintTileResidencyTests|RasterRevisionStoreTests|DepositionRendererTests'`.
- [x] Mainline commit coverage complete (planned checkpoint: `refactor(raster): use sparse paint tiles`).

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

- [x] Add pure model tests for add/delete/reorder/visibility/opacity/lock and
  active-layer fallback.
- [x] Add independent CPU/GPU blend differentials and transparent-edge tests.
- [x] Add deterministic current-project schema-4 round trips and prove native
  schemas 1, 2, 3, and unknown future versions fail typed before payload reads
  or renderer allocation. Do not add a native migration path.
- [x] Add a 2048 x 2048 eight-layer residency test and fail if live GPU tile
  bytes exceed the configured budget.
- [x] Verify undo/redo targets the original layer ID after reorder.
- [x] Run `swift test --filter 'LayerStackTests|LayerCompositorTests|PatternRasterExportCodecTests|PatternProjectBridgeTests'`.
- [x] Mainline commit coverage complete (planned checkpoint: `feat(layers): add bounded linear compositor`).

**Stage D exit:** Low-flow buildup and blending match independent linear-light
references, high precision no longer requires full-canvas per-layer textures,
and eight-layer composition respects memory, history, export, and ordering.

### Task 14A: Hard-Cut Native Brushes To Current Schema 2

After Stage D acceptance and before Stage E, execute the dependency-ordered
cutover in
[`task-14a-current-native-brush-cutover-brief.md`](../../../.superpowers/sdd/2026-08-01-brush-engine-corrective-program/task-14a-current-native-brush-cutover-brief.md).
Migrate every native producer, external-import mapper output, harness, and test
factory to definition schema 2/package-manifest schema 2 first. Then delete
native v1 DTOs, adapters, hashes, compiler/runtime/stabilizer/whole-stroke
branches, retired aliases, compatibility fixtures/tests, repeated validation,
and post-deletion source scanners. Procreate/Synthetic parsers and genuine
resource/capability/ownership boundaries remain.

Task 14A finishes with one current-route functional/performance gate and one
scoped review. Task 15 may not begin before it is green.

---

## Stage E — Make Tip Resources And Backends Explicit

### Task 15: Compile Tip Support, Mips, And Reusable Procedural Masks

**Dependency:** Task 14A is complete; all native brush inputs are trusted exact
definition schema 2/package-manifest schema 2 values.

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

- [x] Add malformed/missing resource and support-bound tests.
- [x] Add mip-selection tests from projected footprint and high-zoom edge tests.
- [x] Add cache hit/miss/eviction metrics and prove warm drawing performs no
  image decode, upload, or pipeline creation.
- [x] Do not add universal border padding; only asset-specific support metadata
  demonstrated by a failing clipping test may request padding.
- [x] Run `swift test --filter 'BrushMaskCacheTests|BrushCompilerTests|DepositionStampInstanceTests'`.
- [x] Mainline commit coverage complete (planned checkpoint: `perf(brush): compile reusable tip support`).

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

- [x] Add pure transform tests for circle, ellipse, chisel, rotation, reflection,
  zoom, backing scale, and missing pressure.
- [x] Add controlled single-dab raster tests requiring cursor/support IoU at
  least 0.85 and maximum support-edge error at most 1.5 logical pixels.
- [x] Route hover and brush-size changes through the descriptor immediately.
- [x] Run `swift test --filter 'BrushCursorDescriptorTests|BrushCursorIntegrationTests|BrushCorrectiveFunctionalTests'`.
- [x] Mainline commit coverage complete (planned checkpoint: `fix(cursor): show evaluated brush footprint`).

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
allowed. Retired native catalog aliases fail explicitly; only current IDs
resolve.
During Task 17 it registers only exact native definition schema 2; Task 18
atomically replaces that registration with schema 3.

- [x] Add duplicate, unknown, version mismatch, deterministic-order, and
  backend-capability tests.
- [x] Register deposition and continuous-ribbon capabilities; the latter may
  remain internal until a brush proves it necessary.
- [x] Remove `usesDestinationSampling` from the deposition function-constant
  path because it is not actually wired; represent it only in a compiled
  canvas-interaction backend contract.
- [x] Keep `secondaryColorMix` as a semantic value but reject nonzero use until
  a backend declares and implements the required color-source capability.
- [x] Run `swift test --filter 'BrushBackendRegistryTests|BrushCompilerTests|DepositionPipelineLibraryTests'`.
- [x] Mainline commit coverage complete (planned checkpoint: `refactor(brush): register static render backends`).

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
size. Schema version 3 becomes the sole accepted native definition version in
the same cutover; older native definitions fail instead of being adapted.
The native package manifest remains exact current schema 2 because its wire
layout does not change; the package validates that its definition payload is
schema 3. Tasks 15 through 17 are prerequisites for this cutover.

- [x] Migrate every in-tree producer to schema 3, delete schema-v1/v2
  decode/compile/hash branches, and prove current single-component and composite
  semantic/raster anchors plus typed old-version rejection.
- [x] Drive component generators from the same authoritative input stream while
  preserving independent resampling and append-only output; never replay the
  retained stroke to produce the secondary component.
- [x] Key randomness by stroke/sample identity, component ordinal,
  component-dab ordinal, and channel so collection order cannot change pixels.
- [x] Carry component identity through compile, resource selection, batching,
  deposition, erase, bounds, cursor support, history, tiling, and radial
  transforms.
- [x] Enforce a maximum of two components in this schema version and include
  component expansion in frame-work, resident-memory, and dab-count budgets.
- [x] Characterize the initial dry composition mode independently. Unknown or
  unsupported required modes fail activation instead of silently flattening.
- [x] Add independent-spacing/dynamics, component-order, random-isolation,
  erase, cursor-union, symmetry, empty-output, budget, and performance tests.
- [x] Run `swift test` plus existing single-component raster anchors.
- [x] Mainline commit coverage complete (planned checkpoint: `feat(brush): add composite dry components`).

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

- [x] Add package boundary tests/build checks proving the release app does not
  link the diagnostics target.
- [x] Move files mechanically first, then expose the smallest public snapshot
  API needed by diagnostics; do not make renderer internals broadly public.
- [x] Update every evidence executable/test dependency and XcodeGen source path.
- [x] Run `swift test` and both Debug and Release macOS app builds.
- [x] Mainline commit coverage complete (planned checkpoint: `refactor(render): isolate diagnostics target`).

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

- [x] Author a neutral anti-aliased ink tip and provenance; do not reuse the
  current fixture as the visual target.
- [x] Use append-only deposition, causal cap termination, short weighted path
  stabilization, and pressure-driven size/flow with explicit mouse neutral.
- [x] Require neutral straight width to be 0.80...1.10 of nominal diameter,
  endpoint retreat at most 1 logical pixel, no centerline gaps, and cursor IoU
  at least 0.90.
- [x] Require CPU preparation p95 below 2 ms, event-to-submit p95 below 8 ms for
  the 60 Hz software trace, missed fraction at most 1%, zero actual replay, and
  no growing backlog.
- [x] Export the Brush Lab edge/join, taper, pressure, erase, responsiveness,
  and prolonged-drawing candidate artifacts with manual status still pending.
- [x] Run the focused tests and production app trace; do not wait for manual
  validation before starting the next brush.
- [x] Mainline commit coverage complete (planned checkpoint: `feat(brush): rebuild technical ink`).

### Task 21: Rebuild Graphite Pencil

**Files:**

- Modify: `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift`
- Add assets under: `Sources/BrushFormat/Resources/Professional/Graphite/`
- Modify: `Tests/EditorCoreTests/ProfessionalBrushDynamicsTests.swift`
- Modify: `Tests/MetalRendererTests/BrushCorrectiveFunctionalTests.swift`
- Modify: `App/PatternSpike/Harness/Scenes/professional-graphite-pencil.json`

- [x] Author at least one irregular tip and one independent paper grain with
  lossless sources, mips, support bounds, scale, and provenance.
- [x] Separate pressure effects on coverage, size, and grain strength; use
  direction/tilt only where the authored physical model justifies them.
- [x] Require the cursor to match measured visible support within 1.5 logical
  pixels, one neutral pass to remain visibly textured, and three repeated
  passes to increase median darkness by at least 20% without one-pass clipping.
- [x] Check grain continuity through turns, zoom, periodic seams, and radial
  transforms; reject screen-locked or swimming texture.
- [x] Pass the same runtime thresholds as Technical Ink at its declared nominal
  workload and export Graphite manual candidates as pending.
- [x] Mainline commit coverage complete (planned checkpoint: `feat(brush): rebuild graphite pencil`).

### Task 22: Rebuild Natural Charcoal

**Files:**

- Modify: `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift`
- Add assets under: `Sources/BrushFormat/Resources/Professional/Charcoal/`
- Modify: `Tests/EditorCoreTests/ProfessionalBrushDynamicsTests.swift`
- Modify: `Tests/MetalRendererTests/BrushCorrectiveFunctionalTests.swift`
- Modify: `App/PatternSpike/Harness/Scenes/professional-natural-charcoal.json`

- [x] Complete Tasks 1–6 of
  `docs/superpowers/plans/2026-08-01-authored-procreate-charcoal-corpus.md` so
  the approved `C Charcoal` and `C Charcoal Soft` parent-plus-`Sub01` archives
  yield native composite packages and honest conversion reports before
  calibrating the product preset.
- [x] Execute focused-plan Task 7 here. Use Laya-owned replacements for the
  absent `Haggard-Oval.png`, `Brush-Preset-Bonobo.png`, and
  `Brush-Artery-Charcoal-Corse.jpg`; derive the grains from the supplied owned
  paper photographs. Do not package or label any absent built-in as exact.
- [x] Keep the supplied `.brushset` on the offline tooling/test path; the native
  definition and admitted resources are the only inputs to `EditorCore` and
  `MetalRenderer`.
- [x] Require parent-only, child-only, and combined evidence so both components
  make a useful measurable contribution and retain independent size, spacing,
  dynamics, grain transform, and random streams.
- [x] At neutral pressure require changed pixels, alpha p50 at least 0.12 inside
  the authored support, alpha p90 at least 0.30, and visible broad-side versus
  edge variation for tilt-capable input.
- [x] Validate tonal buildup, grain scale, seam continuity, footprint-matched
  erase, mouse fallback, cursor/support agreement, and low/mid/high spatial
  frequency energy. One-pixel tip, zero-grain, disabled-component,
  merged-random-stream, shrunken-support, and seam negative controls must fail.
- [x] Pass runtime thresholds at nominal and large sizes and export Charcoal
  manual candidates as pending.
- [x] Mainline commit coverage complete (planned checkpoint: `feat(brush): rebuild natural charcoal`).

### Task 23: Rebuild Chisel Marker And Gate The Ribbon Backend

**Files:**

- Modify: `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift`
- Add assets under: `Sources/BrushFormat/Resources/Professional/Chisel/`
- Modify: `Sources/PatternEngine/BrushDirectionTracker.swift`
- Modify: `Tests/MetalRendererTests/BrushCorrectiveFunctionalTests.swift`
- Modify: `App/PatternSpike/Harness/Scenes/professional-chisel-marker.json`
- Conditionally create: `Sources/MetalRenderer/BrushBackend/ContinuousRibbonEncoder.swift`

- [x] First implement with filtered shortest-angle stamp frames and
  footprint-aware spacing; add fan interpolation only where the turn test shows
  an uncovered wedge.
- [x] Require zero isolated icicle components, maximum turn protrusion at most
  0.15 nominal diameter, no interior gap wider than 2 logical pixels, and
  consistent broad/edge widths.
- [x] If automated turn thresholds pass with stamps, keep the stamp backend as
  the candidate; the final manual round may still reopen this decision.
- [x] If an automated threshold fails, capture the failing raster/metric,
  implement the registered continuous-ribbon backend for Chisel only, and
  rerun the complete deposition/tiling/symmetry/erase/history matrix.
- [x] Pass nominal and tight-turn performance thresholds and export Chisel
  manual candidates as pending.
- [x] Mainline commit coverage complete (planned checkpoint: `feat(brush): rebuild chisel marker`).

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

- [x] Move display composition and commit/history bridging into the focused
  units after characterization tests are green.
- [x] Delete the debug old-runtime switch and all unreachable replay-layer
  product code.
- [x] Prove compile-time ownership by keeping `PatternEngine` independent and
  `MetalRendererDiagnostics -> MetalRenderer` one-way.
- [x] Run `swift test` and a production trace that proves input/frame CPU work is
  independent of completed-stroke length and no completed-stroke replay loop is
  reachable.
- [x] Mainline commit coverage complete (planned checkpoint: `refactor(render): finish stroke runtime split`).

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

- [x] Require deterministic canonical pixels across batching, prediction,
  viewport zoom, and display cadence.
- [x] Require canonical parity across preview/commit, exactly one history
  command, correct undo/redo, and cancel preserving prior pixels.
- [x] Require no input-path decode/upload/pipeline creation/GPU wait, zero
  append-only actual replay, bounded queue and residency, and no monotonic
  latency growth.
- [x] Add negative controls that independently fail each gate category.
- [x] Run `swift test`, then `swift run BrushCorrectiveEvidenceGate`.
- [x] Mainline commit coverage complete (planned checkpoint: `test(brush): add corrective evidence gate`).

### Task 26: Exercise The Production macOS UI And Export Manual Candidates

**Files:**

- Create: `App/UITests/BrushCorrectiveUITests.swift`
- Modify: `App/PatternSpike/Debug/DebugPerformanceHUD.swift`
- Modify: `App/PatternSpike/Debug/DebugPerformanceMonitor.swift`
- Modify: `App/PatternSpike/BrushLab/BrushLabSession.swift`
- Modify: `docs/superpowers/milestones/12-professional-dry-media.md`
- Modify: `docs/superpowers/16-reference-sheet.md`

- [x] Launch the production app, select every candidate brush, set exact sizes,
  perform straight/curved/long strokes, change tools, erase, undo/redo, clear,
  switch plain/periodic/radial on a clean canvas, and verify controls remain
  responsive while drawing.
- [x] Capture canvas PNG, screen image, input trace, semantic hash, HUD snapshot,
  and isolated JSONL segment for every test workload.
- [x] Keep the HUD compact at bottom-right and verify opening it with tilde does
  not steal numeric input focus or alter shortcut routing.
- [x] Export complete Brush Lab candidate cards and reference artifacts for
  look, feel, texture, joins, pressure, tilt, erase, responsiveness, and
  prolonged use. Leave their result explicitly pending; do not request manual
  validation during Stage G.
- [x] Build the iPadOS simulator target and run platform-independent app tests;
  record physical Pencil/120 Hz/thermal/memory/Wacom checks as pending.
- [x] Update milestones with the five-state vocabulary only:
  `engineIntegrated`, `softwarePerformancePassed`, `manualQualityPassed`,
  `physicalProfilePassed`, and `productAccepted`.
- [x] Mainline commit coverage complete (planned checkpoint: `docs(brush): publish corrective evidence status`).

### Task 27: Complete Automated Integration Verification

- [x] Run `swift test` with normal parallelism, then rerun only documented
  process-global Metal/harness suites with `--no-parallel`.
- [x] Regenerate Xcode projects and build Debug/Release macOS plus Debug iPadOS
  simulator targets with warnings treated as errors.
- [x] Run one full 10-second and accelerated 10-minute integration trace;
  compare hashes, p95/p99 latency, memory high-water, and cache behavior. The
  mandatory repeated performance round runs after this stage.
- [x] Inspect the production app log for input-path allocations, actual replay,
  unbounded queue growth, GPU waits, dropped actual input, and silent fallback.
- [x] Set `engineIntegrated` only when every Stage G automated gate is green.
  Keep every candidate laboratory-only while `manualQualityPassed` is pending.
- [x] Do not mark `softwarePerformancePassed`, `physicalProfilePassed`,
  `realtime120`, or `productAccepted` here.
- [x] Mainline commit coverage complete (planned checkpoint: `feat(brush): complete automated integration`).

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

- [x] Run the complete cold/warm, nominal/large/max-size,
  plain/periodic/radial, maximum-symmetry, cache-churn, memory-pressure,
  10-second, and accelerated 10-minute matrix three times for all four brushes.
- [x] Compare FPS, frame p95/p99, event-to-submit p95/p99, CPU preparation, GPU
  duration, missed-frame fraction, actual/predicted queue depth, backlog
  high-water, memory high-water, cache hits/misses, input-path work, and
  canonical hashes across runs.
- [x] Treat any visible-output, cursor, endpoint, texture, continuity, control,
  determinism, backlog, latency, memory, or silent-fallback failure as an
  implementation defect. Fix it, add a focused regression, and rerun the
  affected cluster. Rerun the full matrix after any performance-path change.
- [x] Set `softwarePerformancePassed` only when all three complete runs pass and
  HUD values agree with persisted JSONL summaries.
- [ ] Requalify the final compositor completion-poll lifecycle repair with the
  complete three-pass matrix on a host that can satisfy the strict timing
  gate. The 2026-08-12 Apple Paravirtual GPU A/B measured 9.13 ms with the fix
  and 9.21 ms without it against the required event-to-submit p95 below 8 ms;
  focused final-source lifecycle and hosted-canvas tests are green.
- [ ] Present the complete candidate set for one user manual round covering
  look, feel, texture, joins, taper, pressure, tilt, buildup, erase, symmetry,
  responsiveness, and prolonged drawing. Record explicit pass/fail notes.
- [ ] Fix every manual failure. Rerun its functional cluster and, when runtime
  or performance code changed, the complete performance matrix. Repeat manual
  validation only for affected cards.
- [ ] Admit only brushes with green automated gates and explicit manual passes
  into `EditorBrushCatalog.drawEntries`; keep any other brush laboratory-only.
- [x] Keep iPad/Pencil/120 Hz/thermal/memory/Wacom evidence pending. Do not set
  `physicalProfilePassed`, `realtime120`, or `productAccepted` without qualifying
  hardware evidence.
- [ ] On qualifying hardware, capture iPad/Pencil/120 Hz/thermal/memory/Wacom
  evidence and set `physicalProfilePassed` only if every physical gate passes.
- [ ] Commit final accepted product state as
  `feat(brush): complete corrective acceptance` after manual and physical gates.

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

- [x] Every confirmed corrective finding maps to a task or an explicit non-goal.
- [x] No archived external claim is used without a repository or primary-source
  confirmation.
- [x] Every behavior-changing task begins with a failing test or measurable
  functional assertion.
- [x] Every new public type has module ownership, serialization implications,
  and concurrency semantics stated.
- [x] Every stage has a runnable exit gate and a small commit boundary.
- [x] No task contains unfinished implementation markers, stub code, or a
  fabricated physical result.
- [x] A final reviewer checks current-only native definition/package/hash and
  PatternFile enforcement, typed old/future-version rejection, preservation of
  external-import provenance/semantic refusal, strict concurrency, color
  transfer count, memory budget, and product status language before execution.
