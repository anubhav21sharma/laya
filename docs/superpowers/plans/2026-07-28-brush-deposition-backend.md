# Brush Deposition Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the compatibility stamp renderer and bounded wash with a
native, specialized, compiled deposition backend for ink, dry media, glaze,
marker, airbrush, and erase.

**Architecture:** Keep PatternEngine's deterministic input-to-logical-dab
front half and the existing canonical raster/history/projection ownership.
Add a full-frame stamp ABI, pure CPU deposition reference, pipeline cache,
immutable material binding, atomic encoder, and bounded frame scheduler.
`GridRenderer` remains the lifecycle facade but delegates all brush-specific
encoding. Built-in and converted native brushes use the same `CompiledBrush`
path.

**Tech Stack:** Swift 6 with complete concurrency checking, Swift Testing,
Metal/MetalKit, C/Metal shared ABI headers, ImageIO/CoreGraphics, CryptoKit,
XcodeGen 2.46+, macOS 14+, iPadOS 18+.

**Approved design:**
`docs/superpowers/specs/2026-07-28-brush-deposition-backend-design.md`

## Global Constraints

- Execute directly on `main`; the user explicitly rejected a worktree.
- Never stage the pre-existing untracked `.vscode/` directory.
- Complete tasks in order. Do not delete the old renderer or bounded wash
  until the native path, lifecycle, failure, and replacement evidence are
  green.
- iPadOS 18+ is primary; macOS 14+ remains the Wacom/development target.
- `PatternEngine` imports no Metal, MetalKit, UIKit, AppKit, or SwiftUI.
- Canonical raster pixels, transaction ownership, history, tiling, symmetry,
  preview, and commit semantics remain unchanged.
- World-space interpolation, dynamics, random decisions, and logical spacing
  occur once before symmetry projection.
- The complete evaluated tip and grain frames transform with every rotational
  or reflected copy.
- Actual/coalesced input alone determines committed pixels. Prediction remains
  replaceable and lower priority.
- Pointer-up produces exactly one raster history command after asynchronous
  authoritative drain and successful GPU completion. Pointer-cancel produces
  none.
- Stroke opacity is applied once at live-surface composition.
- Erase uses destination-out with the selected eraser's ordinary coverage and
  dynamics and never reads brush color.
- File I/O, package/image decode, mip generation, texture upload, pipeline
  creation, buffer growth, and synchronous GPU waits never occur during input
  handling or frame encoding.
- Authoritative backlog may carry across frames but may not drop dabs, alter
  spacing/dynamics, rerun randomness, or reduce symmetry.
- Queue overflow, allocation, reservation, encoding, submission, and GPU
  failure terminate only the transient stroke and preserve committed pixels
  and history.
- Built-in and converted assets use one resource binding path. Required
  resources never silently fall back.
- Any `Dictionary` or `Set` traversal affecting hashes, serialized evidence,
  pipeline keys, cache eviction, instance order, or pixels must first sort by
  an explicit stable key.
- Old rendered pixels, Slice 4 parity, and the legacy renderer are not
  acceptance targets.
- Bounded wash is removed, not migrated. Wet concentration, pickup, smudge,
  and Wet Mix remain loadable/inspectable but cannot activate before Stage 6.
- Existing non-obsolete raster, history, transaction, symmetry, package,
  parser, resource, and failure gates remain mandatory.
- Historical old-pixel images/traces are archived as non-gating evidence; they
  are never regenerated to match the new renderer.
- New visual baselines become gating only after explicit user approval.
- Metal tests may skip only when `MTLCreateSystemDefaultDevice()` returns
  `nil`. Pure tests never skip.
- Correctness never becomes “pending.” Exit 2 is reserved for physical-device
  performance gates after all software correctness checks pass.
- Every task follows red-green-refactor, runs its focused tests, runs
  `git diff --check`, and commits only its own files.

---

## File And Ownership Map

### New MetalRenderer deposition units

- `Sources/MetalRenderer/Deposition/DepositionContracts.swift` — ABI version,
  frame budgets, preparation failures, and shared feature flags.
- `Sources/MetalRenderer/Deposition/DepositionStampInstance.swift` —
  projection-to-wire packing and stable instance identity.
- `Sources/MetalRenderer/Deposition/DepositionReference.swift` — pure CPU
  coverage, accumulation, edge, and destination-out oracle.
- `Sources/MetalRenderer/Deposition/DepositionPipelineLibrary.swift` —
  function-constant render-pipeline preparation/cache.
- `Sources/MetalRenderer/Deposition/DepositionMaterialBinding.swift` —
  immutable uniforms and deterministic texture slots.
- `Sources/MetalRenderer/Deposition/DepositionEncoder.swift` — atomic
  reservation, packing, texture binding, and instanced draw encoding.
- `Sources/MetalRenderer/Deposition/FrameScheduler.swift` — bounded
  authoritative/predicted queues and per-frame selection.
- `Sources/MetalRenderer/Deposition/DepositionTelemetry.swift` — counters and
  percentiles shared by the renderer, Brush Lab, and evidence.

### Existing production files extended

- `Sources/PatternEngine/StrokeRenderStyle.swift` — portable semantic render
  identity.
- `Sources/PatternEngine/BrushModel/BrushDefinition.swift` — Stage 4 material
  validation only; no Metal knowledge.
- `Sources/EditorCore/Brushes/AnchorBrushCatalog.swift` — six native anchors.
- `Sources/EditorCore/Brushes/StageFourAnchorDefinitions.swift` — direct
  `BrushDefinition` construction.
- `Sources/MetalRenderer/BrushCompiler/BrushDeviceProfile.swift` — explicit
  deposition frame budget.
- `Sources/MetalRenderer/BrushCompiler/CompiledBrush.swift` — prepared
  pipeline/material binding and semantic identity.
- `Sources/MetalRenderer/BrushCompiler/BrushCompiler.swift` — pipeline
  preparation and definition-only built-in compilation.
- `Sources/CShaderTypes/include/ShaderTypes.h` — versioned deposition wire ABI.
- `Sources/MetalRenderer/ShaderABI.swift` — complete Swift/C ABI checks.
- `Sources/MetalRenderer/Shaders.metal` — specialized coverage/deposition
  functions and shared composition.
- `Sources/MetalRenderer/DabInstanceBufferPool.swift` — new instance stride,
  unchanged atomic leasing.
- `Sources/MetalRenderer/LiveStroke.swift` — projected deposition records.
- `Sources/MetalRenderer/GridPipelineLibrary.swift` — display, commit, resize,
  and non-brush pipelines only after migration.
- `Sources/MetalRenderer/GridRenderer.swift` — compiled-brush capture,
  scheduler, encoder delegation, and existing transactional lifecycle.
- `Sources/MetalRenderer/GridRenderer+Harness.swift` — native diagnostics and
  fault injection.
- `Sources/MetalRenderer/MetalRendererError.swift` — typed Stage 4 failures.
- `App/PatternSpike/ContentView.swift` — asynchronous default/eraser bootstrap.
- `App/PatternSpike/EditorSessionController.swift` — async native selection.
- `App/PatternSpike/BrushLab/BrushLabSession.swift` and
  `BrushLabView.swift` — production activation, manual cards, evidence export.
- `Package.swift`, `App/project.yml`, and harness launch code — Stage 4 gate.

### Legacy production units removed only in Task 10

- `Sources/MetalRenderer/Brush/BrushMaterialState.swift`
- `Sources/MetalRenderer/Brush/BoundedWashSurface.swift`
- `Sources/MetalRenderer/ProjectedStampInstance.swift`
- generic stamp and wash pipeline states in `GridPipelineLibrary`
- legacy material-family and wash functions in `Shaders.metal`
- bounded-wash catalog/UI entries and active tests
- active Slice 4 parity/wash runner and gate dependencies

`BrushRecipe` and `LegacyBrushRecipeAdapter` remain only for historical schema
and converter compatibility tests. Production rendering must not read
`BrushProgram.compatibilityRecipe`.

### Verification units

- `Tests/MetalRendererTests/DepositionContractsTests.swift`
- `Tests/MetalRendererTests/DepositionStampInstanceTests.swift`
- `Tests/MetalRendererTests/DepositionReferenceTests.swift`
- `Tests/MetalRendererTests/DepositionPipelineLibraryTests.swift`
- `Tests/MetalRendererTests/DepositionMaterialBindingTests.swift`
- `Tests/MetalRendererTests/DepositionEncoderTests.swift`
- `Tests/MetalRendererTests/FrameSchedulerTests.swift`
- `Tests/MetalRendererTests/DepositionRendererTests.swift`
- `Tests/MetalRendererTests/DepositionMetamorphicTests.swift`
- `Tests/MetalRendererTests/DepositionLegacyRemovalTests.swift`
- `Tests/MetalRendererTests/DepositionHarnessRunnerTests.swift`
- `Tests/MetalRendererTests/DepositionEvidenceValidatorTests.swift`
- `Sources/MetalRenderer/Capture/DepositionHarnessRunner.swift`
- `Sources/MetalRenderer/Capture/DepositionEvidenceValidator.swift`
- `Sources/BrushDepositionEvidenceGate/main.swift`
- `scripts/verify-brush-stage4.sh`

---

## Approved-Spec Coverage

- Architecture, activation, pipeline specialization: Tasks 1, 4, 7, 8.
- Full affine stamp/grain ABI and symmetry semantics: Tasks 2, 3, 7, 9.
- Native accumulation/edge equations: Task 3.
- Atomic batching and bounded scheduling: Tasks 5 and 6.
- Transaction, prediction, preview/commit, and failure safety: Tasks 6, 7, 9.
- Six fresh native brush anchors: Task 8.
- Custom converted resource rendering and cache lifecycle: Tasks 4, 8, 9.
- Legacy/bounded-wash removal: Task 10.
- Brush Lab manual acceptance: Task 11.
- Software, build, analysis, artifact, and hardware-pending gates: Task 12.

---

### Task 1: Define Deposition Activation, Identity, And Frame Budgets

**Files:**

- Create:
  `Sources/MetalRenderer/Deposition/DepositionContracts.swift`
- Modify:
  `Sources/MetalRenderer/BrushCompiler/BrushDeviceProfile.swift`
- Modify:
  `Sources/MetalRenderer/BrushCompiler/BrushCompilationReport.swift`
- Modify:
  `Sources/MetalRenderer/BrushCompiler/CompiledBrush.swift`
- Modify:
  `Sources/MetalRenderer/BrushCompiler/BrushCompiler.swift`
- Modify:
  `Sources/PatternEngine/StrokeRenderStyle.swift`
- Create:
  `Tests/MetalRendererTests/DepositionContractsTests.swift`
- Modify:
  `Tests/MetalRendererTests/BrushDeviceProfileTests.swift`
- Modify:
  `Tests/MetalRendererTests/BrushCompilerTests.swift`
- Create:
  `Tests/PatternEngineTests/StrokeRenderStyleTests.swift`

**Interfaces:**

- Consumes:
  `BrushDefinition`, `BrushProgram`, `BrushPackage.contentHash`,
  `BrushDeviceProfile`, and current compiler latest-request-wins behavior.
- Produces:

```swift
public enum DepositionABI {
    public static let version: UInt16 = 1
}

public enum DepositionFrameBudgetError: Error, Equatable, Sendable {
    case nonpositive(String)
    case perFrameExceedsPending(String)
    case invalidInFlightUploadBufferCount
}

public struct DepositionFrameBudget: Equatable, Sendable {
    public let cpuPreparationNanoseconds: UInt64
    public let maximumAuthoritativeInstances: Int
    public let maximumPredictedInstances: Int
    public let maximumPendingAuthoritativeInstances: Int
    public let maximumPendingPredictedInstances: Int
    public let inFlightUploadBufferCount: Int

    public init(
        cpuPreparationNanoseconds: UInt64,
        maximumAuthoritativeInstances: Int,
        maximumPredictedInstances: Int,
        maximumPendingAuthoritativeInstances: Int,
        maximumPendingPredictedInstances: Int,
        inFlightUploadBufferCount: Int
    ) throws
}

public enum DepositionPreparationError: Error, Equatable, Sendable {
    case unsupportedInteraction(BrushInteractionMode)
    case unsupportedEdgeTreatment(BrushEdgeTreatment)
    case missingRequiredResource(String)
    case pipelinePreparationFailed(String)
}

public enum BrushRenderIdentityError: Error, Equatable, Sendable {
    case emptyDefinitionID
    case invalidSemanticHash
}

public struct BrushRenderIdentity: Equatable, Sendable {
    public let definitionID: BrushRecipeID
    public let semanticHash: String

    public init(
        definitionID: BrushRecipeID,
        semanticHash: String
    ) throws
}
```

- `BrushDeviceProfile` gains:

```swift
public let depositionFrameBudget: DepositionFrameBudget
```

- `CompiledBrush` stores the identity created by `BrushCompiler` after the
  package hash has been validated:

```swift
public let renderIdentity: BrushRenderIdentity
```

- `StrokeRenderStyle` gains a required `renderIdentity`. Transitional test
  helpers may derive it from their prepared compiled fixture, never from a
  UUID or process-random value.

- [ ] **Step 1: Write failing pure contract tests**

Add tests with exact bounds:

```swift
@Test func frameBudgetRejectsZeroOrNegativeCapacity() {
    #expect(throws: DepositionFrameBudgetError.self) {
        try DepositionFrameBudget(
            cpuPreparationNanoseconds: 0,
            maximumAuthoritativeInstances: 0,
            maximumPredictedInstances: 0,
            maximumPendingAuthoritativeInstances: 0,
            maximumPendingPredictedInstances: 0,
            inFlightUploadBufferCount: 0
        )
    }
}

@Test func renderIdentityRequiresCanonicalSHA256() {
    #expect(throws: BrushRenderIdentityError.invalidSemanticHash) {
        try BrushRenderIdentity(
            definitionID: BrushRecipeID("native.ink"),
            semanticHash: "not-a-hash"
        )
    }
}
```

Also test that a device profile preserves an explicitly supplied budget and
derives deterministic defaults from target refresh rate without inspecting a
model-name string.

- [ ] **Step 2: Run the tests and verify red**

Run:

```bash
swift test --filter 'DepositionContractsTests|BrushDeviceProfileTests'
```

Expected: FAIL because the new types and profile property do not exist.

- [ ] **Step 3: Implement validated contracts**

Use throwing initializers. Require:

- positive CPU nanoseconds and all capacities;
- predicted per-frame capacity no larger than pending predicted capacity;
- authoritative per-frame capacity no larger than pending authoritative
  capacity;
- in-flight count in `1...8`;
- exactly 64 lowercase hexadecimal semantic-hash characters;
- nonempty definition ID.

Derive default budgets from refresh tier and existing capacity:

```swift
let realtime120 = targetFramesPerSecond >= 120
let budget = try DepositionFrameBudget(
    cpuPreparationNanoseconds: realtime120 ? 1_500_000 : 2_000_000,
    maximumAuthoritativeInstances:
        GridCanvasContract.instanceCapacity,
    maximumPredictedInstances:
        TransientStrokeBufferContract.visibleEpochProjectedInstanceCapacity,
    maximumPendingAuthoritativeInstances:
        GridCanvasContract.pendingCapacity,
    maximumPendingPredictedInstances:
        TransientStrokeBufferContract.visibleEpochProjectedInstanceCapacity,
    inFlightUploadBufferCount:
        GridCanvasContract.inFlightBufferCount
)
```

These are software scheduling defaults, not physical-device acceptance
claims.

- [ ] **Step 4: Add Stage 4 compiler rejection**

Before image decode or allocation, reject:

```swift
guard program.definition.material.interaction == .none else {
    throw DepositionPreparationError.unsupportedInteraction(
        program.definition.material.interaction
    )
}
guard program.definition.material.edgeTreatment != .wetConcentration else {
    throw DepositionPreparationError.unsupportedEdgeTreatment(
        .wetConcentration
    )
}
```

Map these to `BrushCompilationFailure(stage: .pipelineSelection, ...)` with
stable reasons `unsupportedInteraction` and `unsupportedWetConcentration`.
Preserve the previously active compiler/cache candidate on failure.

- [ ] **Step 5: Test identity and active-candidate preservation**

Add tests:

- `compiledBrushRenderIdentityUsesPackageSemanticHash`
- `wetDefinitionFailsBeforeDecodeUploadOrActivation`
- `wetConcentrationFailsBeforeDecodeUploadOrActivation`
- `failedReplacementLeavesPriorCompiledBrushPinned`
- `equalDefinitionWithDifferentResourceHashHasDifferentRenderIdentity`

Assert package/image/upload/activation counters do not advance for early
unsupported-capability failures.

- [ ] **Step 6: Run focused and compatibility tests**

Run:

```bash
swift test --filter 'DepositionContractsTests|BrushDeviceProfileTests|BrushCompilerTests|StrokeRenderStyleTests'
git diff --check
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/PatternEngine/StrokeRenderStyle.swift \
  Sources/MetalRenderer/Deposition/DepositionContracts.swift \
  Sources/MetalRenderer/BrushCompiler \
  Tests/PatternEngineTests/StrokeRenderStyleTests.swift \
  Tests/MetalRendererTests/DepositionContractsTests.swift \
  Tests/MetalRendererTests/BrushDeviceProfileTests.swift \
  Tests/MetalRendererTests/BrushCompilerTests.swift
git commit -m "feat(brush): define deposition contracts"
```

---

### Task 2: Add The Full-Frame Deposition Stamp ABI

**Files:**

- Modify:
  `Sources/CShaderTypes/include/ShaderTypes.h`
- Create:
  `Sources/MetalRenderer/Deposition/DepositionStampInstance.swift`
- Modify:
  `Sources/MetalRenderer/ShaderABI.swift`
- Create:
  `Tests/MetalRendererTests/DepositionStampInstanceTests.swift`
- Modify:
  `Tests/MetalRendererTests/ShaderABILayoutTests.swift`

**Interfaces:**

- Consumes:
  `LogicalDab`, `CellFragment`, `PatternClipHalfPlane`,
  `BrushRenderIdentity`, and `DepositionABI.version`.
- Produces C/Metal:

```c
typedef struct PatternDepositionStampInstance {
    PatternFloat4 tipFrame0;
    PatternFloat4 tipFrame1;
    PatternFloat4 primaryGrainFrame0;
    PatternFloat4 primaryGrainFrame1;
    PatternFloat4 secondaryGrainFrame0;
    PatternFloat4 secondaryGrainFrame1;
    PatternFloat4 premultipliedColor;
    PatternFloat4 coverageInputs;
    PatternClipHalfPlane clip0;
    PatternClipHalfPlane clip1;
    PatternClipHalfPlane clip2;
    PatternClipHalfPlane clip3;
    PatternUInt4 identity;
    PatternUInt4 metadata;
    PatternFloat4 reserved0;
    PatternFloat4 reserved1;
} PatternDepositionStampInstance;
```

Add the missing shared vector alias alongside `PatternFloat4`:

```c
#if defined(__METAL_VERSION__)
typedef uint4 PatternUInt4;
#else
typedef vector_uint4 PatternUInt4;
#endif
```

Exact meanings:

- `tipFrame0 = (xAxis.x, xAxis.y, yAxis.x, yAxis.y)`
- `tipFrame1 = (translation.x, translation.y, radius, 0)`
- each grain pair stores its two axes and translation;
- absent grain frames are zero and their metadata bit is clear;
- `premultipliedColor` is evaluated dab color before stroke opacity;
- `coverageInputs = (opacity, flow, hardness, materialContribution)`;
- `identity = (ordinalLow, ordinalHigh, isometryOrdinal, flags)`;
- `metadata = (clipCount, shapeFlags, grainFlags, ABI version)`;
- reserved fields are zero.

The layout is exactly 256 bytes, 16-byte aligned. No legacy
`brushAttributes` payload survives.

- Produces Swift:

```swift
struct ProjectedDepositionRecord: Equatable, Sendable {
    let identity: UInt64
    let instance: PatternDepositionStampInstance
    let radialPage: RadialPageIdentity?
}

extension PatternDepositionStampInstance {
    init(
        fragment: CellFragment,
        dab: LogicalDab,
        logicalOrdinal: UInt64,
        isometryOrdinal: UInt8
    ) throws
}
```

Implement `ProjectedDepositionRecord.==` explicitly by comparing stable
identity, radial page, and every frozen instance field; do not assume the
C-imported wire struct synthesizes `Equatable`.

- [ ] **Step 1: Write failing layout and packing tests**

Cover:

- exact size `256`, alignment `16`, and each offset;
- ordinal high/low round trip;
- four/zero clip planes and overflow rejection;
- absent/present primary and secondary grain frames;
- rotated and reflected affine frames;
- color/opacity/flow/hardness/material packing;
- reserved bytes exactly zero;
- nonfinite input rejection.

Example:

```swift
@Test func depositionInstanceHasFrozenWireLayout() {
    #expect(MemoryLayout<PatternDepositionStampInstance>.size == 256)
    #expect(MemoryLayout<PatternDepositionStampInstance>.stride == 256)
    #expect(MemoryLayout<PatternDepositionStampInstance>.alignment == 16)
}
```

- [ ] **Step 2: Run red tests**

Run:

```bash
swift test --filter 'DepositionStampInstanceTests|ShaderABILayoutTests'
```

Expected: FAIL because the shared struct does not exist.

- [ ] **Step 3: Add the C ABI and Swift packer**

Use explicit vector fields only. Never embed Swift `Bool`, enums, pointers,
arrays with compiler-dependent layout, or `MTLTexture` references.

Pack the exact projected tip and projected grain transforms. Do not reconstruct
direction or grain orientation from screen coordinates.

- [ ] **Step 4: Extend `ShaderABI` fail-fast validation**

Validate the 256-byte stride and each field offset through C-exported
`offsetof` constants or exact shared-header helper functions. Call
`ShaderABI.preconditionValid()` from renderer initialization before resource
allocation.

- [ ] **Step 5: Add a Metal diagnostic round-trip**

Add a diagnostic vertex/compute function that writes selected instance fields
to a readback buffer. The test compiles `Shaders.metal` with the inlined shared
header and verifies Swift-packed values after one GPU dispatch. A forged
metadata ABI version must produce a different diagnostic value and fail.

- [ ] **Step 6: Run focused tests and compile both app targets**

Run:

```bash
swift test --no-parallel --filter 'DepositionStampInstanceTests|ShaderABILayoutTests'
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData build \
  CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedDataPad build \
  CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/CShaderTypes/include/ShaderTypes.h \
  Sources/MetalRenderer/ShaderABI.swift \
  Sources/MetalRenderer/Deposition/DepositionStampInstance.swift \
  Tests/MetalRendererTests/DepositionStampInstanceTests.swift \
  Tests/MetalRendererTests/ShaderABILayoutTests.swift
git commit -m "feat(brush): add deposition stamp ABI"
```

---

### Task 3: Implement The New Deposition Equations And CPU Reference

**Files:**

- Create:
  `Sources/MetalRenderer/Deposition/DepositionReference.swift`
- Modify:
  `Sources/CShaderTypes/include/ShaderTypes.h`
- Modify:
  `Sources/MetalRenderer/Shaders.metal`
- Create:
  `Tests/MetalRendererTests/DepositionReferenceTests.swift`
- Create:
  `Tests/MetalRendererTests/DepositionShaderSourceTests.swift`

**Interfaces:**

- Consumes:
  `BrushCoverageDefinition`, `BrushMaterialDefinition`,
  `PatternDepositionStampInstance`, and deterministic texture samples.
- Produces:

```swift
struct DepositionCoverageSamples: Equatable, Sendable {
    let primaryShape: Float
    let secondaryShape: Float?
    let primaryGrain: Float?
    let secondaryGrain: Float?
    let signedTipEdgeDistance: Float
}

struct DepositionReferenceMaterial: Equatable, Sendable {
    let secondaryShapeCombination: BrushShapeCombinationMode?
    let primaryGrainStrength: Float?
    let secondaryGrainStrength: Float?
    let accumulationMode: BrushAccumulationMode
    let edgeTreatment: BrushEdgeTreatment
    let materialStrength: Float
    let accumulationLimit: Float
}

enum DepositionReference {
    static func coverage(
        samples: DepositionCoverageSamples,
        instance: PatternDepositionStampInstance,
        material: DepositionReferenceMaterial
    ) -> Float

    static func accumulateAlpha(
        current: Float,
        baseCoverage: Float,
        flowCoverage: Float,
        mode: BrushAccumulationMode,
        accumulationLimit: Float
    ) -> Float

    static func destinationOut(
        destinationPremultiplied: SIMD4<Float>,
        eraseCoverage: Float,
        strokeOpacity: Float
    ) -> SIMD4<Float>
}
```

The exact accumulation equations are copied from approved design §8:

```swift
case .opaque:
    next = current + (1 - current) * baseCoverage
case .flow:
    next = current + (1 - current) * flowCoverage
case .uniformGlaze:
    next = max(current, flowCoverage)
case .intenseGlaze:
    let intense = 1 - (1 - flowCoverage) * (1 - flowCoverage)
    next = current + (1 - current) * intense
case .destinationOut:
    next = current + (1 - current) * flowCoverage
```

All values clamp to `[0, accumulationLimit]`.

- [ ] **Step 1: Write table-driven failing CPU tests**

Cover:

- replace/multiply/minimum/maximum secondary-shape combinations;
- zero/one/two grain layers and declared strengths;
- hardness at 0, 0.5, 1;
- tip threshold and antialiasing;
- deterministic dry breakup;
- marker edge/body behavior;
- opaque/flow/uniform/intense accumulation across repeated dabs;
- destination-out RGB and alpha;
- erase independence from brush color;
- NaN/out-of-range input rejection or clamping at the declared boundary.

Use exact hand-calculated cases, not values copied from implementation.

- [ ] **Step 2: Run red CPU tests**

Run:

```bash
swift test --filter DepositionReferenceTests
```

Expected: FAIL because `DepositionReference` does not exist.

- [ ] **Step 3: Implement the pure reference**

Keep this file independent of `MTLDevice`, `MTLTexture`, and UI frameworks.
Texture sampling is an input value, so every equation is deterministic and
cheap to test.

Dry breakup uses only grain sample, signed edge distance, hardness, and
material strength. Marker overlap uses only declared coverage inputs and edge
distance. Neither reads wall-clock time or generates per-pixel randomness.

- [ ] **Step 4: Write failing shader-source specialization tests**

Assert the shader declares function constants for:

- secondary shape;
- primary grain;
- secondary grain;
- accumulation mode;
- edge treatment.

Assert the new deposition fragment contains no:

- `PatternMaterialWireInk`, `Dry`, `Glaze`, or `BoundedWash`;
- `materialFamily` branch;
- `patternWash` call;
- fallback texture selection.

- [ ] **Step 5: Implement matching Metal functions**

Add:

```metal
static float patternDepositionCoverage(...);
static float patternDepositionAccumulatedAlpha(...);
fragment float4 patternDepositionFragment(...);
```

Use function constants to compile out absent layers and unused edge paths.
Keep live-surface composition separate so stroke opacity is still applied once.

- [ ] **Step 6: Add CPU/GPU differential fixtures**

Render synthetic 1×1 and small R8 shape/grain textures offscreen for every
accumulation and edge mode. Compare BGRA8 channels with maximum absolute delta
`1`. Add one negative-control fragment that changes intense glaze and prove the
validator rejects it.

- [ ] **Step 7: Run focused tests and shader compilation**

Run:

```bash
swift test --no-parallel --filter 'DepositionReferenceTests|DepositionShaderSourceTests'
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData build \
  CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/MetalRenderer/Deposition/DepositionReference.swift \
  Sources/MetalRenderer/Shaders.metal \
  Sources/CShaderTypes/include/ShaderTypes.h \
  Tests/MetalRendererTests/DepositionReferenceTests.swift \
  Tests/MetalRendererTests/DepositionShaderSourceTests.swift
git commit -m "feat(brush): add native deposition equations"
```

---

### Task 4: Prepare Specialized Pipelines And Immutable Material Bindings

**Files:**

- Create:
  `Sources/MetalRenderer/Deposition/DepositionPipelineLibrary.swift`
- Create:
  `Sources/MetalRenderer/Deposition/DepositionMaterialBinding.swift`
- Modify:
  `Sources/MetalRenderer/BrushCompiler/CompiledBrush.swift`
- Modify:
  `Sources/MetalRenderer/BrushCompiler/BrushCompiler.swift`
- Modify:
  `Sources/MetalRenderer/GridPipelineLibrary.swift`
- Create:
  `Tests/MetalRendererTests/DepositionPipelineLibraryTests.swift`
- Create:
  `Tests/MetalRendererTests/DepositionMaterialBindingTests.swift`
- Modify:
  `Tests/MetalRendererTests/BrushCompilerTests.swift`

**Interfaces:**

```swift
public struct DepositionPipelineKey: Hashable, Sendable {
    public let brush: BrushPipelineKey
    public let abiVersion: UInt16
    public let colorPixelFormatRawValue: UInt
    public let sampleCount: Int
}

@MainActor
public final class DepositionPipelineBinding {
    public let key: DepositionPipelineKey
    public let state: any MTLRenderPipelineState
}

@MainActor
protocol DepositionPipelinePreparing: AnyObject {
    func prepare(
        for key: DepositionPipelineKey
    ) async throws -> DepositionPipelineBinding
}

@MainActor
public final class DepositionPipelineLibrary:
    DepositionPipelinePreparing
{
    public func prepare(
        for key: DepositionPipelineKey
    ) async throws -> DepositionPipelineBinding

    public func preparedBinding(
        for key: DepositionPipelineKey
    ) throws -> DepositionPipelineBinding
}

@MainActor
public struct DepositionMaterialBinding {
    public let uniforms: PatternDepositionMaterialUniforms
    public let textures: DepositionTextureBindings

    public init(compiledBrush: CompiledBrush) throws
}
```

`CompiledBrush` gains immutable `depositionPipeline` and
`depositionMaterial`. `BrushCompiler` receives a
`DepositionPipelinePreparing` dependency. Tests use a deterministic fake;
production uses `DepositionPipelineLibrary`.

- [ ] **Step 1: Write failing key/cache tests**

Test:

- equal semantic features produce equal stable keys;
- ABI, pixel format, sample count, accumulation, edge, and feature flags each
  change the key;
- repeated preparation returns the same state identity;
- concurrent latest requests do not publish stale bindings;
- failed preparation does not replace a ready binding;
- `preparedBinding` never compiles.

- [ ] **Step 2: Run red tests**

Run:

```bash
swift test --filter 'DepositionPipelineLibraryTests|DepositionMaterialBindingTests'
```

Expected: FAIL because the library/binding types do not exist.

- [ ] **Step 3: Implement function-constant pipeline creation**

Use `MTLFunctionConstantValues` for the five Stage 4 feature groups. Build the
render pipeline against `patternProjectedDepositionVertex` and
`patternDepositionFragment`.

Use asynchronous Metal pipeline preparation. Cache insertion occurs only after
successful creation. Sort any diagnostic key serialization explicitly.

- [ ] **Step 4: Implement deterministic texture binding**

Map definition layer order to fixed slots:

```swift
enum DepositionTextureSlot: Int, CaseIterable {
    case primaryShape = 0
    case secondaryShape = 1
    case primaryGrain = 2
    case secondaryGrain = 3
}
```

Resolve exact resource IDs from the definition and compiled texture dictionary.
Analytic sources leave the slot absent and set the matching uniform kind.
Missing required resources throw before activation.

- [ ] **Step 5: Wire pipeline preparation into compilation**

The compiler sequence becomes:

```text
definition/program
  -> resource work/decode/upload/cache candidate
  -> material binding
  -> async pipeline preparation
  -> immutable CompiledBrush
  -> cache/activation publication
```

Increment activation counters only after all stages succeed. Add
`compileAndActivate(definition:)` that wraps a direct native definition in an
empty-resource `BrushPackage`; it is valid only when all referenced resources
are analytic or explicit built-in fallbacks.

- [ ] **Step 6: Add failure/counter tests**

Test:

- pipeline prepare precedes activation;
- forced pipeline failure keeps old compiled brush active;
- no texture decode/upload repeats on pipeline-cache hit;
- no pipeline preparation repeats on resource-cache hit;
- missing custom texture fails material binding;
- wet packages fail before pipeline preparation;
- compile-by-definition and equivalent package produce the same semantic hash.

- [ ] **Step 7: Run focused tests**

Run:

```bash
swift test --no-parallel --filter 'DepositionPipelineLibraryTests|DepositionMaterialBindingTests|BrushCompilerTests'
git diff --check
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/MetalRenderer/Deposition/DepositionPipelineLibrary.swift \
  Sources/MetalRenderer/Deposition/DepositionMaterialBinding.swift \
  Sources/MetalRenderer/BrushCompiler \
  Sources/MetalRenderer/GridPipelineLibrary.swift \
  Tests/MetalRendererTests/DepositionPipelineLibraryTests.swift \
  Tests/MetalRendererTests/DepositionMaterialBindingTests.swift \
  Tests/MetalRendererTests/BrushCompilerTests.swift
git commit -m "feat(brush): prepare deposition pipelines"
```

---

### Task 5: Add Atomic Deposition Packing And Encoding

**Files:**

- Create:
  `Sources/MetalRenderer/Deposition/DepositionEncoder.swift`
- Modify:
  `Sources/MetalRenderer/DabInstanceBufferPool.swift`
- Modify:
  `Sources/MetalRenderer/DabBufferReservationState.swift`
- Modify:
  `Sources/MetalRenderer/LiveStroke.swift`
- Create:
  `Tests/MetalRendererTests/DepositionEncoderTests.swift`
- Modify:
  `Tests/MetalRendererTests/DabInstanceBufferPoolTests.swift`
- Modify:
  `Tests/MetalRendererTests/DabBufferReservationStateTests.swift`

**Interfaces:**

```swift
struct DepositionEncodingOutcome: Equatable, Sendable {
    let instanceCount: Int
    let uploadCount: Int
    let textureLevelRange: ClosedRange<Int>?
}

@MainActor
struct DepositionEncoder {
    mutating func preflight(
        records: [ProjectedDepositionRecord],
        binding: DepositionPipelineBinding,
        material: DepositionMaterialBinding
    ) throws -> PreparedDepositionEncoding

    mutating func encode(
        _ prepared: PreparedDepositionEncoding,
        into target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws -> DepositionEncodingOutcome

    mutating func abandon(_ prepared: PreparedDepositionEncoding)
}
```

`PreparedDepositionEncoding` owns every required ring-buffer lease. Its
initializer is internal and it cannot exist with a partial reservation.

- [ ] **Step 1: Write failing pure reservation tests**

Test:

- zero records produce no lease and no encoder;
- exact chunk counts at capacity boundaries;
- all leases acquired or none;
- one failed lease returns all earlier leases;
- overflow is detected before multiplication/allocation;
- record order remains stable across chunks;
- an abandoned preparation returns every lease exactly once.

- [ ] **Step 2: Run red tests**

Run:

```bash
swift test --filter 'DepositionEncoderTests|DabInstanceBufferPoolTests|DabBufferReservationStateTests'
```

Expected: FAIL because `DepositionEncoder` does not exist.

- [ ] **Step 3: Retarget the ring pool to the 256-byte ABI**

Allocate each fixed buffer for:

```swift
GridCanvasContract.instanceCapacity
    * MemoryLayout<PatternDepositionStampInstance>.stride
```

Keep triple buffering and explicit completion release. Do not allocate a
temporary `[PatternDepositionStampInstance]`; pack directly into mapped buffer
memory.

- [ ] **Step 4: Implement atomic preflight**

Validate before any live clear or render-pass creation:

- prepared pipeline key/ABI;
- target pixel format;
- material/texture completeness;
- exact record and chunk counts;
- upload and queue limits;
- every lease;
- every instance finite and ABI-compatible.

- [ ] **Step 5: Implement encoding**

Bind:

- one render pipeline;
- one instance buffer range per chunk;
- one material uniform block;
- the fixed four texture slots;
- target render pass with the accumulation mode's specialized blend state.

Draw only the supplied records. The encoder does not generate, project, sort,
or discard dabs.

- [ ] **Step 6: Add real-Metal and failure tests**

Test:

- one pipeline/resource set per batch;
- exact instance count and ordering;
- correct texture-slot identity;
- forced encoder absence releases all leases;
- forced command-buffer absence releases all leases;
- no live target is cleared when preflight fails;
- no buffer growth after warm-up;
- no file/decode/upload/pipeline counters change during encode.

- [ ] **Step 7: Run focused tests**

Run:

```bash
swift test --no-parallel --filter 'DepositionEncoderTests|DabInstanceBufferPoolTests|DabBufferReservationStateTests'
git diff --check
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/MetalRenderer/Deposition/DepositionEncoder.swift \
  Sources/MetalRenderer/DabInstanceBufferPool.swift \
  Sources/MetalRenderer/DabBufferReservationState.swift \
  Sources/MetalRenderer/LiveStroke.swift \
  Tests/MetalRendererTests/DepositionEncoderTests.swift \
  Tests/MetalRendererTests/DabInstanceBufferPoolTests.swift \
  Tests/MetalRendererTests/DabBufferReservationStateTests.swift
git commit -m "feat(brush): encode deposition atomically"
```

---

### Task 6: Add The Bounded Authoritative/Prediction Frame Scheduler

**Files:**

- Create:
  `Sources/MetalRenderer/Deposition/FrameScheduler.swift`
- Create:
  `Sources/MetalRenderer/Deposition/DepositionTelemetry.swift`
- Create:
  `Tests/MetalRendererTests/FrameSchedulerTests.swift`
- Create:
  `Tests/MetalRendererTests/DepositionTelemetryTests.swift`

**Interfaces:**

```swift
struct ScheduledDepositionFrame: Equatable, Sendable {
    let authoritative: [ProjectedDepositionRecord]
    let predicted: [ProjectedDepositionRecord]
    let authoritativeRemaining: Int
    let predictedRemaining: Int
}

struct FrameScheduler: Sendable {
    mutating func enqueueAuthoritative(
        _ records: [ProjectedDepositionRecord]
    ) throws

    mutating func replacePrediction(
        _ records: [ProjectedDepositionRecord]
    ) throws

    mutating func nextFrame(
        budget: DepositionFrameBudget
    ) -> ScheduledDepositionFrame

    mutating func discardPrediction()
    mutating func reset()

    var authoritativeIsDrained: Bool { get }
}

public struct DepositionTelemetrySnapshot: Equatable, Sendable {
    public let authoritativeBacklog: Int
    public let predictedBacklog: Int
    public let backlogHighWater: Int
    public let encodedInstanceCount: UInt64
    public let bufferHighWater: Int
    public let missedFrameCount: UInt64
}
```

- [ ] **Step 1: Write failing scheduler tests**

Cover:

- authoritative always precedes prediction;
- predicted replacement is atomic and does not affect authoritative records;
- exact records survive multi-frame carry;
- no duplicated or reordered identity;
- queue capacity boundary succeeds;
- capacity + 1 fails without mutation;
- pointer-up drain state ignores prediction;
- reset clears both queues and telemetry;
- different frame partitioning yields the same concatenated authoritative
  identity sequence.

- [ ] **Step 2: Run red tests**

Run:

```bash
swift test --filter 'FrameSchedulerTests|DepositionTelemetryTests'
```

Expected: FAIL because scheduler/telemetry types do not exist.

- [ ] **Step 3: Implement fixed-capacity queues**

Use `ContiguousArray` with capacity reserved at initialization. Do not use
front-removal proportional to queue length; maintain a head index and compact
only on bounded cold/reset paths.

Queue validation occurs before append. Predicted replacement builds a
validated candidate before swapping.

- [ ] **Step 4: Implement frame selection**

Take at most the profile's authoritative count, then prediction count. CPU
time measurement may end selection early, but never after a record has been
removed without being returned in the scheduled frame.

The scheduler itself never touches Metal or sleeps.

- [ ] **Step 5: Add telemetry percentile utility**

Use bounded fixed-window storage for CPU/submit/GPU durations. Percentile
calculation runs outside input event handling. Define stable empty-window
output and monotonic saturating counters.

- [ ] **Step 6: Run focused and stress tests**

Include a 1,000,000-record synthetic sequence fed in legal chunks and assert
bounded queue capacity, exact order for accepted work, and explicit overflow.

Run:

```bash
swift test --filter 'FrameSchedulerTests|DepositionTelemetryTests'
git diff --check
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/MetalRenderer/Deposition/FrameScheduler.swift \
  Sources/MetalRenderer/Deposition/DepositionTelemetry.swift \
  Tests/MetalRendererTests/FrameSchedulerTests.swift \
  Tests/MetalRendererTests/DepositionTelemetryTests.swift
git commit -m "feat(brush): schedule deposition work"
```

---

### Task 7: Route `GridRenderer` Through Compiled Deposition

**Files:**

- Modify:
  `Sources/MetalRenderer/GridRenderer.swift`
- Modify:
  `Sources/MetalRenderer/GridRenderer+Harness.swift`
- Modify:
  `Sources/MetalRenderer/MetalRendererError.swift`
- Modify:
  `Sources/MetalRenderer/LiveStroke.swift`
- Modify:
  `Tests/MetalRendererTests/RendererTransactionTests.swift`
- Modify:
  `Tests/MetalRendererTests/RendererRasterOperationTests.swift`
- Create:
  `Tests/MetalRendererTests/DepositionRendererTests.swift`

**Interfaces:**

```swift
@MainActor
public func activateDrawBrush(_ brush: CompiledBrush) throws

@MainActor
public func activateEraserBrush(_ brush: CompiledBrush) throws
```

`ActiveStrokeExecution` gains:

```swift
let compiledBrush: CompiledBrush
let renderIdentity: BrushRenderIdentity
var commitRequested: Bool
var scheduler: FrameScheduler
```

`GridRenderer.beginStroke` chooses draw or eraser compiled state from the
style's composite mode and verifies exact `BrushRenderIdentity` before
`resetLiveState`.

- [ ] **Step 1: Write failing activation tests**

Test:

- pointer-down with no prepared brush fails before mutation;
- definition/hash mismatch fails before mutation;
- draw and erase select distinct compiled brushes;
- a captured brush survives later editor selection and cache churn;
- activation during a stroke fails and does not alter the active stroke;
- unsupported wet brush cannot install;
- activation itself performs no decode/upload/pipeline work.

- [ ] **Step 2: Run red tests**

Run:

```bash
swift test --no-parallel --filter 'DepositionRendererTests|RendererTransactionTests'
```

Expected: FAIL because compiled activation APIs do not exist.

- [ ] **Step 3: Add compiled activation state**

Keep `StrokeRenderStyle` Metal-free. Store only the active compiled draw and
eraser brushes in MetalRenderer. Installation validates prepared pipeline,
material binding, semantic hash, backend, and ABI before replacing prior
state.

- [ ] **Step 4: Replace projection output packing**

Keep existing `TilingProjection` and half-open fragment production. Replace
`ProjectedDabRecord` construction with `ProjectedDepositionRecord` and
`PatternDepositionStampInstance(fragment:dab:...)`.

Determine `isometryOrdinal` from the compiled symmetry operation, not
collection iteration order.

- [ ] **Step 5: Route actual/predicted records through `FrameScheduler`**

Actual generator state still advances transactionally on input. Projection
records enqueue after the entire sample succeeds. Predicted replacement builds
from the authoritative checkpoint and swaps only the predicted queue.

- [ ] **Step 6: Delegate frame uploads to `DepositionEncoder`**

`draw(in:)` asks the scheduler for a frame, preflights the encoder, then clears
or mutates live targets only after preflight succeeds.

Completion handlers settle exact upload ranges and return leases. Completed
stroke length is represented by the live texture, not retained instances.

- [ ] **Step 7: Make finish asynchronous**

Pointer-up:

1. finishes the authoritative generator;
2. discards prediction;
3. marks `commitRequested`;
4. returns without `waitUntilCompleted`;
5. later frames drain scheduled/in-flight authoritative work;
6. only then prepare and submit the existing single raster commit;
7. publish one completion/history command after success.

- [ ] **Step 8: Add failure and lifecycle tests**

Inject:

- projected-instance overflow;
- scheduler overflow;
- reservation failure;
- encoder absence;
- command-buffer absence;
- GPU completion failure;
- stale completion;
- revision allocation/commit failure.

For every case assert:

- canonical revision and bytes unchanged;
- history unchanged;
- transient queues/surfaces cleared;
- captured resources released;
- next valid stroke succeeds.

- [ ] **Step 9: Add prediction/partition tests**

Assert:

- prediction on/off committed bytes equal;
- different legal frame partitions committed bytes equal;
- actual random/dab identity unchanged by prediction;
- preview and commit differ by at most one channel value;
- pointer-cancel creates no commit.

- [ ] **Step 10: Run focused integration tests**

Run:

```bash
swift test --no-parallel --filter 'DepositionRendererTests|RendererTransactionTests|RendererRasterOperationTests'
git diff --check
```

Expected: PASS. The legacy code may still compile in this intermediate task,
but no new native test may invoke it.

- [ ] **Step 11: Commit**

```bash
git add Sources/MetalRenderer/GridRenderer.swift \
  Sources/MetalRenderer/GridRenderer+Harness.swift \
  Sources/MetalRenderer/MetalRendererError.swift \
  Sources/MetalRenderer/LiveStroke.swift \
  Tests/MetalRendererTests/DepositionRendererTests.swift \
  Tests/MetalRendererTests/RendererTransactionTests.swift \
  Tests/MetalRendererTests/RendererRasterOperationTests.swift
git commit -m "feat(brush): render compiled deposition"
```

---

### Task 8: Add Six Native Anchors And Production/Brush Lab Activation

**Files:**

- Create:
  `Sources/EditorCore/Brushes/StageFourAnchorDefinitions.swift`
- Modify:
  `Sources/EditorCore/Brushes/AnchorBrushCatalog.swift`
- Modify:
  `Sources/EditorCore/Model/EditorModel.swift`
- Modify:
  `App/PatternSpike/ContentView.swift`
- Modify:
  `App/PatternSpike/EditorSessionController.swift`
- Modify:
  `App/PatternSpike/Panels/EditorTopBar.swift`
- Modify:
  `App/PatternSpike/BrushLab/BrushLabSession.swift`
- Modify:
  `App/PatternSpike/BrushLab/BrushLabView.swift`
- Modify:
  `Tests/EditorCoreTests/AnchorBrushCatalogTests.swift`
- Modify:
  `Tests/EditorCoreTests/EditorModelTests.swift`
- Modify:
  `App/Tests/EditorSessionControllerTests.swift`
- Modify:
  `App/Tests/ContentViewLifecycleTests.swift`
- Modify:
  `App/Tests/BrushLabSessionTests.swift`
- Modify:
  `Tests/BrushConverterIntegrationTests/SyntheticBrushCompilerIntegrationTests.swift`

**Interfaces:**

```swift
public enum StageFourAnchorDefinitions {
    public static let ink: BrushDefinition
    public static let dryMedia: BrushDefinition
    public static let glaze: BrushDefinition
    public static let marker: BrushDefinition
    public static let airbrush: BrushDefinition
    public static let eraser: BrushDefinition
}

public enum AnchorBrushCatalog {
    public static let ink: AnchorBrushEntry
    public static let dryMedia: AnchorBrushEntry
    public static let glaze: AnchorBrushEntry
    public static let marker: AnchorBrushEntry
    public static let airbrush: AnchorBrushEntry
    public static let eraser: AnchorBrushEntry
    public static let drawAnchors: [AnchorBrushEntry]
    public static let all: [AnchorBrushEntry]
}
```

Use stable IDs:

```text
builtin.native-ink
builtin.native-dry-media
builtin.native-glaze
builtin.native-marker
builtin.native-airbrush
builtin.native-eraser
```

Every definition is built directly. No anchor calls
`LegacyBrushRecipeAdapter`.

- [ ] **Step 1: Write failing catalog tests**

Assert:

- exact six IDs and stable order;
- five draw anchors and one eraser;
- every program's `compatibilityRecipe == nil`;
- every interaction is `.none`;
- each family has the approved accumulation/edge combination;
- eraser uses `.destinationOut`;
- no ID or display name contains “wash”;
- stale `builtin.bounded-wash` resolves to default ink plus diagnostic;
- fixed definitions validate and compile deterministically.

- [ ] **Step 2: Run red catalog tests**

Run:

```bash
swift test --filter 'AnchorBrushCatalogTests|EditorModelTests'
```

Expected: FAIL because the native anchors do not exist.

- [ ] **Step 3: Build direct native definitions**

Use existing immutable groups and dynamics mappings. Keep tuning deliberately
diagnostic rather than claiming Stage 5 quality:

- ink: hard round, `.flow + .none`;
- dry media: textured shape/grain, `.flow + .dryBreakup`;
- glaze: `.uniformGlaze + .none`;
- marker: chisel, `.uniformGlaze + .markerOverlap`;
- airbrush: soft round, low flow, `.flow + .none`;
- eraser: hard round, `.destinationOut + .none`.

All six declare `realtime120` intent and resource/dimension limits. Actual tier
acceptance remains measured.

- [ ] **Step 4: Add asynchronous app bootstrap**

Change `ContentView` initialization to async:

```swift
.task { await initializeRendererIfNeeded() }
```

Create one shader library, `DepositionPipelineLibrary`, `GridRenderer`, and
`BrushCompiler`. Compile default ink and eraser before setting
`CanvasState.ready`. Failure produces the existing unavailable UI.

Other built-ins compile on selection; the old draw brush remains active until
the requested brush succeeds.

- [ ] **Step 5: Make editor selection transactional**

Inject the definition compiler into `EditorSessionController` so its existing
construction sites can supply a deterministic test closure while production
captures the app-owned `BrushCompiler`:

```swift
private let compileDefinition:
    @MainActor (BrushDefinition) async throws -> CompiledBrush

init(
    ...,
    compileDefinition:
        @escaping @MainActor
        (BrushDefinition) async throws -> CompiledBrush
)

func selectBrush(_ id: BrushRecipeID) async
```

Sequence:

1. reject selection during active edit;
2. compile native definition/cache hit;
3. install compiled draw brush;
4. only then confirm `EditorModel.selectedRecipeID`;
5. on failure preserve prior renderer and model selection and report error.

Change `EditorTopBar.anchorRecipeBinding` to start a main-actor `Task` that
awaits `selectBrush`, then restores editor focus. Remove the synchronous
`handleRecipe` selection route rather than leaving two sources of truth.

Eraser is compiled at bootstrap and selected by stroke tool without replacing
the draw selection.

- [ ] **Step 6: Activate converted packages in Brush Lab**

After `BrushCompiler.compileAndActivate(package:)`, call
`renderer.activateDrawBrush(compiled)`, install its program/render identity in
the diagnostic selection, and enable production drawing regardless of
`compatibilityRecipe`.

Wet/interaction packages retain reports but display the typed unsupported
activation state.

- [ ] **Step 7: Add app and integration tests**

Test:

- bootstrap compiles ink/eraser before ready;
- selection changes only after successful compilation;
- failed/pending selection leaves old brush active;
- eraser stroke uses compiled native eraser;
- Brush Lab custom shape/grain package draws through production renderer;
- Brush Lab wet package stays inspectable but unavailable;
- custom package semantic hash reaches `StrokeRenderStyle.renderIdentity`;
- selection change mid-stroke affects only the next stroke.

- [ ] **Step 8: Run focused and platform builds**

Run:

```bash
swift test --no-parallel --filter 'AnchorBrushCatalogTests|EditorModelTests|EditorSessionControllerTests|BrushLabSessionTests|SyntheticBrushCompilerIntegrationTests'
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData build \
  CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedDataPad build \
  CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/EditorCore/Brushes \
  Sources/EditorCore/Model/EditorModel.swift \
  App/PatternSpike/ContentView.swift \
  App/PatternSpike/EditorSessionController.swift \
  App/PatternSpike/Panels/EditorTopBar.swift \
  App/PatternSpike/BrushLab \
  Tests/EditorCoreTests \
  App/Tests/EditorSessionControllerTests.swift \
  App/Tests/ContentViewLifecycleTests.swift \
  App/Tests/BrushLabSessionTests.swift \
  Tests/BrushConverterIntegrationTests/SyntheticBrushCompilerIntegrationTests.swift
git commit -m "feat(brush): add native deposition anchors"
```

---

### Task 9: Add Native Offscreen, Metamorphic, Resource, And Failure Evidence

**Files:**

- Create:
  `Sources/MetalRenderer/Capture/DepositionHarnessRunner.swift`
- Create:
  `Sources/MetalRenderer/Capture/DepositionEvidence.swift`
- Create:
  `Sources/MetalRenderer/Capture/DepositionEvidenceValidator.swift`
- Modify:
  `Sources/MetalRenderer/Capture/HarnessScene.swift`
- Modify:
  `App/PatternSpike/Harness/HarnessLaunch.swift`
- Create:
  `Tests/MetalRendererTests/DepositionHarnessRunnerTests.swift`
- Create:
  `Tests/MetalRendererTests/DepositionEvidenceValidatorTests.swift`
- Create:
  `Tests/MetalRendererTests/DepositionMetamorphicTests.swift`
- Create:
  `App/PatternSpike/Harness/Scenes/deposition-*.json`
- Create paired:
  `App/PatternSpike/Harness/Scenes/deposition-*-negative-control.json`

**Required scene stems:**

```text
deposition-ink
deposition-dry
deposition-glaze
deposition-marker
deposition-airbrush
deposition-erase
deposition-custom-asymmetric
deposition-layer-matrix
deposition-stamp-size-mips
deposition-kinematics
deposition-periodic-seams
deposition-radial-reflection
deposition-prediction
deposition-preview-commit
deposition-cache-pinning
deposition-failure-matrix
```

**Evidence schema:**

```swift
struct DepositionSceneEvidence: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let scene: String
    let definitionID: String
    let semanticHash: String
    let pipelineKey: String
    let abiVersion: UInt16
    let resourceBytes: Int
    let textureLevels: [String: Int]
    let logicalDabCount: Int
    let projectedInstanceCount: Int
    let canonicalSHA256: String
    let cpuReferenceSHA256: String?
    let maximumCPUGPUChannelDelta: UInt8?
    let previewCommitMaximumChannelDelta: UInt8
    let telemetry: DepositionTelemetryEvidence
    let invariantResults: [String: Bool]
}
```

- [ ] **Step 1: Write failing schema/scene-set tests**

Require the exact 16 positive and 16 negative stems. Reject missing, duplicate,
unknown, unsorted, or wrong-schema scenes.

- [ ] **Step 2: Run red tests**

Run:

```bash
swift test --filter 'DepositionHarnessRunnerTests|DepositionEvidenceValidatorTests'
```

Expected: FAIL because runner/evidence types do not exist.

- [ ] **Step 3: Implement the native runner**

The runner:

- creates/loads the native `BrushPackage`;
- compiles pipeline/resources;
- activates the compiled brush;
- replays normalized fixed traces;
- captures live, committed, canonical, and optional CPU-reference PNGs;
- writes evidence and benchmark JSON atomically;
- records no third-party texture bytes;
- runs one process per scene to isolate Metal state.

- [ ] **Step 4: Implement family/layer/resource scenes**

Cover all six anchors, built-in and custom asymmetric assets, one/two shape
layers, zero/one/two grains, combination modes, min/default/max size, and mip
transitions.

The custom asset scene must prove exact resource IDs and non-fallback textures
reach fixed shader slots.

- [ ] **Step 5: Implement seam and affine scenes**

Cover every periodic family and finite radial rotation/reflection. Use an
asymmetric directional tip and grain so incorrect handedness or screen-space
reconstruction is visible and machine-detectable.

- [ ] **Step 6: Implement metamorphic scenes**

Named invariant results:

```text
predictionOnOffEqual
batchPartitionsEqual
symmetryOrderEqual
tilingPeriodTranslationEqual
zoomIndependent
eraseColorIndependent
reflectionHandednessCorrect
cancelPreservesCanonical
```

Compare canonical bytes/digests, not only logical dabs.

- [ ] **Step 7: Implement cache/failure scenes**

Exercise:

- inactive LRU eviction;
- active compiled brush pinning;
- selection churn;
- package/image/upload/pipeline counters unchanged in stroke;
- pipeline, buffer, encoder, allocation, completion, and revision failures;
- next valid stroke after failure.

Every failure must preserve canonical bytes/revision/history and clear
transient state.

- [ ] **Step 8: Add meaningful negative controls**

Each paired negative changes exactly one authoritative expectation:

- wrong family/accumulation;
- fallback texture identity;
- missing secondary layer;
- wrong mip;
- seam delta;
- reflection flag;
- prediction commits pixels;
- preview/commit mismatch;
- active resource eviction;
- failure unexpectedly mutates canonical/history.

Each negative process must exit exactly `1`. A negative control that passes is
a gate failure.

- [ ] **Step 9: Run focused matrix**

Run:

```bash
swift test --no-parallel --filter 'DepositionHarnessRunnerTests|DepositionEvidenceValidatorTests|DepositionMetamorphicTests|RadialHarnessTests|HarnessSceneTests'
git diff --check
```

Then run every positive/negative scene through the existing app
`--harness-scene` subprocess contract. Expected: positives exit `0`; negatives
exit `1`.

- [ ] **Step 10: Commit**

```bash
git add Sources/MetalRenderer/Capture/DepositionHarnessRunner.swift \
  Sources/MetalRenderer/Capture/DepositionEvidence.swift \
  Sources/MetalRenderer/Capture/DepositionEvidenceValidator.swift \
  Sources/MetalRenderer/Capture/HarnessScene.swift \
  App/PatternSpike/Harness \
  Tests/MetalRendererTests/DepositionHarnessRunnerTests.swift \
  Tests/MetalRendererTests/DepositionEvidenceValidatorTests.swift \
  Tests/MetalRendererTests/DepositionMetamorphicTests.swift
git commit -m "test(brush): add deposition evidence matrix"
```

---

### Task 10: Remove The Legacy Renderer And Bounded Wash

**Files:**

- Delete:
  `Sources/MetalRenderer/Brush/BrushMaterialState.swift`
- Delete:
  `Sources/MetalRenderer/Brush/BoundedWashSurface.swift`
- Delete:
  `Sources/MetalRenderer/ProjectedStampInstance.swift`
- Delete/replace:
  `Tests/MetalRendererTests/BrushMaterialStateTests.swift`
- Delete/replace:
  `Tests/MetalRendererTests/BoundedWashSurfaceTests.swift`
- Create:
  `Tests/MetalRendererTests/DepositionLegacyRemovalTests.swift`
- Modify:
  `Sources/MetalRenderer/GridRenderer.swift`
- Modify:
  `Sources/MetalRenderer/GridPipelineLibrary.swift`
- Modify:
  `Sources/MetalRenderer/Shaders.metal`
- Modify:
  `Sources/CShaderTypes/include/ShaderTypes.h`
- Modify:
  `Sources/EditorCore/Brushes/AnchorBrushCatalog.swift`
- Modify:
  `Sources/MetalRenderer/Capture/BrushFoundationEvidenceValidator.swift`
- Modify:
  `Tests/MetalRendererTests/BrushFoundationEvidenceGateTests.swift`
- Modify:
  `Tests/BrushConverterIntegrationTests/SyntheticBrushCompilerIntegrationTests.swift`
- Modify:
  `scripts/verify-brush-stage3.sh`
- Delete:
  `Sources/MetalRenderer/Capture/SliceFourHarnessRunner.swift`
- Delete:
  `Sources/SliceFourEvidenceGate/main.swift`
- Delete:
  `Tests/MetalRendererTests/SliceFourHarnessRunnerTests.swift`
- Delete:
  `scripts/verify-slice4.sh`
- Modify:
  `Package.swift`
- Modify:
  `Sources/MetalRenderer/Capture/HarnessScene.swift`
- Modify:
  `App/PatternSpike/Harness/HarnessLaunch.swift`
- Move all 16 exact `App/PatternSpike/Harness/Scenes/slice4-*.json` files,
  unchanged, into:
  `docs/superpowers/archive/evidence/stage2-brush-renderer/scenes/`
- Create:
  `docs/superpowers/archive/evidence/stage2-brush-renderer/README.md`

Remove the active `SliceFourEvidenceGate` product/target only after Task 9's
replacement tests pass.

**Interfaces:**

- Production code must contain no read of `compatibilityRecipe`.
- Production shader code must contain no legacy material-family/wash wire
  constants or functions.
- `BrushRecipe`/adapter remain only in historical, converter, and pure schema
  tests.

- [ ] **Step 1: Write a failing source-boundary test**

The test scans only production paths and rejects:

```text
compatibilityRecipe
BrushMaterialState
BoundedWashSurface
PatternMaterialWireBoundedWash
patternWash
pipelines.stamp
washDeposit
washSoften
washResolve
```

It also asserts `AnchorBrushCatalog` has no bounded-wash entry.

- [ ] **Step 2: Run the source test and verify red**

Run:

```bash
swift test --filter DepositionLegacyRemovalTests
```

Expected: FAIL with the current production references listed.

- [ ] **Step 3: Remove the generic/wash renderer state**

Delete active shape/grain legacy resolver state, legacy material uniforms,
bounded wash work plans/history/surfaces, generic stamp encoding, and wash
resolve/clear/soften passes.

Keep display, commit, resize, replay clear, radial mapping, and raster
transaction functions.

- [ ] **Step 4: Remove old shader ABI/functions**

Delete the old projected instance, material-family enum, bounded-wash uniforms,
and unused generic fragment. Keep only functions still consumed by native
deposition, display, commit, export, resize, and replay.

- [ ] **Step 5: Archive evidence without rewriting it**

Move old scene/baseline data with a README containing:

- originating commit;
- reason for archival;
- explicit statement that pixels are non-gating;
- replacement Stage 4 scene names.

Do not update their expected digests or render them with the new backend.

- [ ] **Step 6: Update non-obsolete gates**

Repoint:

- logical/program/resource/cache assertions to native anchors;
- prediction/transaction/symmetry/failure assertions to new deposition tests;
- Stage 3 wet activation from compatibility wash behavior to typed
  `unsupportedWetConcentration`/`unsupportedInteraction`.

Do not remove parser, package v1/v2, converter, resource, transaction, or
symmetry checks.

- [ ] **Step 7: Run source audit and broad tests**

Run:

```bash
swift test --filter DepositionLegacyRemovalTests
swift test --no-parallel
./scripts/verify-brush-stage3.sh
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData build \
  CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedDataPad build \
  CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: all software checks PASS. Stage 3 must remain green with its explicit
wet rejection.

- [ ] **Step 8: Commit**

Stage only the explicit removal, replacement, archive, and updated tests:

```bash
git add Sources/MetalRenderer/GridRenderer.swift \
  Sources/MetalRenderer/GridPipelineLibrary.swift \
  Sources/MetalRenderer/Shaders.metal \
  Sources/MetalRenderer/Capture/BrushFoundationEvidenceValidator.swift \
  Sources/MetalRenderer/Capture/HarnessScene.swift \
  Sources/CShaderTypes/include/ShaderTypes.h \
  Sources/EditorCore/Brushes/AnchorBrushCatalog.swift \
  Tests/MetalRendererTests/DepositionLegacyRemovalTests.swift \
  Tests/MetalRendererTests/BrushFoundationEvidenceGateTests.swift \
  Tests/BrushConverterIntegrationTests/SyntheticBrushCompilerIntegrationTests.swift \
  App/PatternSpike/Harness/HarnessLaunch.swift \
  scripts/verify-brush-stage3.sh \
  Package.swift \
  docs/superpowers/archive/evidence/stage2-brush-renderer
git add -u Sources/MetalRenderer/Brush \
  Sources/MetalRenderer/ProjectedStampInstance.swift \
  Sources/MetalRenderer/Capture/SliceFourHarnessRunner.swift \
  Sources/SliceFourEvidenceGate \
  Tests/MetalRendererTests/BrushMaterialStateTests.swift \
  Tests/MetalRendererTests/BoundedWashSurfaceTests.swift \
  Tests/MetalRendererTests/SliceFourHarnessRunnerTests.swift \
  App/PatternSpike/Harness/Scenes \
  scripts/verify-slice4.sh
git commit -m "refactor(brush): remove legacy deposition"
```

Before committing, inspect `git diff --cached --name-only` and unstage any
unrelated path. Never stage `.vscode/`.

---

### Task 11: Add Brush Lab Manual Cards And Complete Diagnostics

**Files:**

- Create:
  `App/PatternSpike/BrushLab/BrushLabManualCard.swift`
- Modify:
  `App/PatternSpike/BrushLab/BrushLabSession.swift`
- Modify:
  `App/PatternSpike/BrushLab/BrushLabView.swift`
- Modify:
  `App/PatternSpike/Debug/DebugPerformanceMonitor.swift`
- Modify:
  `App/Tests/BrushLabSessionTests.swift`
- Modify:
  `App/Tests/DebugPerformanceMonitorTests.swift`

**Interfaces:**

```swift
enum BrushLabManualGesture: String, Codable, CaseIterable, Sendable {
    case tap
    case slowLine
    case fastLine
    case curve
    case zigZag
    case directionReversal
}

struct BrushLabManualCard: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let brushID: String
    let gesture: BrushLabManualGesture
    let diameter: Float
    let pressureProfile: String
    let inputCapabilities: [String]
    let documentConfiguration: SymmetryDocumentConfiguration
    let customResourceFixture: String?
}

struct BrushLabManualAssessment: Codable, Equatable, Sendable {
    let cardID: String
    let responsiveness: String?
    let edgeQuality: String?
    let textureCohesion: String?
    let buildup: String?
    let symmetryBehavior: String?
    let eraserMatch: String?
    let notes: String?
}
```

Assessment fields remain unset until the user records them. The app never
self-approves visual quality.

- [ ] **Step 1: Write failing card-generation tests**

Require a deterministic sorted card matrix covering:

- all six anchors;
- tap/slow/fast/curve/zig-zag/reversal;
- minimum/default/maximum size;
- low/medium/high pressure;
- available tilt/azimuth/roll capabilities;
- plain, periodic, reflected, and finite radial;
- transparent/opaque backgrounds;
- custom asymmetric resource case;
- prediction on/off.

Assert stable IDs and byte-identical JSON across two fresh sessions.

- [ ] **Step 2: Run red tests**

Run:

```bash
swift test --filter 'BrushLabSessionTests|DebugPerformanceMonitorTests'
```

Expected: FAIL because manual-card types do not exist.

- [ ] **Step 3: Implement fixed cards and programmatic trace replay**

Cards reuse normalized trace fixtures and production renderer entry points.
They do not synthesize pixels directly or bypass `EditorSessionController`.

Allow selecting one card, replaying it, clearing, and exporting its exact
input/brush/projection identity.

- [ ] **Step 4: Add compact diagnostics**

Expose:

- definition/package hash;
- pipeline key and ABI;
- texture IDs/levels and resident bytes;
- authoritative/predicted backlog and high water;
- encoded dabs/instances;
- CPU preparation, event-to-submit, GPU completion percentiles;
- missed frames and buffer high water;
- last typed failure stage.

Keep the UI internal and compact; no public editor polish.

- [ ] **Step 5: Export reproducible manual evidence**

Export JSON plus rendered PNGs and telemetry atomically. Include empty
assessment fields and never claim pass/fail before user input.

- [ ] **Step 6: Run focused tests and app builds**

Run:

```bash
swift test --filter 'BrushLabSessionTests|DebugPerformanceMonitorTests'
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData build \
  CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedDataPad build \
  CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add App/PatternSpike/BrushLab \
  App/PatternSpike/Debug/DebugPerformanceMonitor.swift \
  App/Tests/BrushLabSessionTests.swift \
  App/Tests/DebugPerformanceMonitorTests.swift
git commit -m "feat(brush-lab): add deposition test cards"
```

---

### Task 12: Add The Commit-Bound Stage 4 Evidence Gate

**Files:**

- Create:
  `Sources/BrushDepositionEvidenceGate/main.swift`
- Create product/target:
  `BrushDepositionEvidenceGate` in `Package.swift`
- Create:
  `scripts/verify-brush-stage4.sh`
- Create:
  `Tests/MetalRendererTests/DepositionEvidenceGateTests.swift`
- Create:
  `docs/superpowers/milestones/11-brush-deposition-backend.md`
- Modify:
  `docs/superpowers/milestones/README.md`

**Artifact root:**

```text
.build/brush-deposition-artifacts/
  provenance.json
  source-tree.txt
  source-tree-terminal.txt
  scene-matrix.json
  performance-status.txt
  artifact-sha256.txt
  positive/<scene>/
    live.png
    committed.png
    canonical.png
    cpu-reference.png
    deposition-evidence.json
    benchmark.json
  negative-control/<scene>/
    stdout.log
    stderr.log
    exit-status.txt
  brush-lab-cards/
  logs/
```

**Exit contract:**

- `0`: every correctness/build/analysis/evidence check passes and required
  physical-device performance profiles pass.
- `1`: any correctness, build, analysis, schema, digest, invariant, negative
  control, or stable-device performance check fails.
- `2`: every software check passes, but physical-device performance remains
  pending because the GPU/profile is recognized as virtual/paravirtual or the
  required physical profiles were not supplied.

- [ ] **Step 1: Write failing validator tests**

Test:

- exact scene set;
- positive/negative directory pairing;
- schema, definition hash, pipeline key, ABI, resource and texture evidence;
- recomputed PNG hashes/dimensions;
- CPU/GPU maximum delta;
- preview/commit delta;
- all metamorphic booleans;
- no hot-path compiler/resource counters;
- each negative exits exactly 1;
- source-tree and commit provenance;
- terminal source-tree equality;
- performance pending only after correctness passes;
- paravirtual profile cannot claim realtime120/60;
- one altered artifact/digest/invariant fails closed.

- [ ] **Step 2: Run red gate tests**

Run:

```bash
swift test --filter 'DepositionEvidenceGateTests|DepositionEvidenceValidatorTests'
```

Expected: FAIL because the executable/script contract does not exist.

- [ ] **Step 3: Implement the evidence executable**

The executable accepts:

```text
--artifacts <absolute-path>
--commit <40-char-sha>
--source-tree-sha256 <64-char-sha>
```

It validates artifacts only; it never launches the app, edits baselines, or
downloads dependencies.

- [ ] **Step 4: Implement the fail-closed shell gate**

`scripts/verify-brush-stage4.sh`:

1. requires a clean committed source tree, ignoring only `.vscode/`;
2. records full commit, Swift/Xcode/XcodeGen, OS, kernel, hardware, GPU, and
   source tree;
3. builds the gate and app harness;
4. runs `swift test --no-parallel`;
5. runs bootstrap;
6. builds and analyzes macOS;
7. builds and analyzes generic iPad Simulator;
8. runs every positive and negative scene in isolated processes;
9. verifies hot-path source/binary boundaries;
10. exports Brush Lab cards headlessly;
11. runs the evidence validator;
12. records terminal source tree and artifact SHA-256 manifest;
13. prints one exact PASS, FAIL, or PERFORMANCE PENDING line.

Use only repository/macOS/Xcode tools. Do not require `jq`.

- [ ] **Step 5: Add performance and hardware policy**

Software smoke checks:

- CPU preparation p95 `< 2 ms`;
- exact 500-dab GPU workload `< 3 ms` only on stable supported Metal;
- completed-stroke length does not grow live frame work;
- no input-path decode/upload/pipeline/allocation/wait.

Physical evidence profiles:

- reference M-series ProMotion iPad at 120 Hz;
- A14-class floor at 60 Hz;
- Pencil;
- Wacom;
- memory warning;
- suspend/resume;
- sustained thermal run;
- true input-to-photon instrumentation.

Missing physical profiles produce exit `2` only after software correctness
passes. Record measurements even when pending.

- [ ] **Step 6: Commit the gate implementation**

Stage only the new executable, script, tests, and milestone skeleton:

```bash
git add Package.swift \
  Sources/BrushDepositionEvidenceGate \
  scripts/verify-brush-stage4.sh \
  Tests/MetalRendererTests/DepositionEvidenceGateTests.swift \
  docs/superpowers/milestones/11-brush-deposition-backend.md \
  docs/superpowers/milestones/README.md
git commit -m "test(brush): add Stage 4 evidence gate"
```

- [ ] **Step 7: Run the full clean committed gate**

Run:

```bash
./scripts/verify-brush-stage4.sh
```

Expected on the current paravirtual Mac:

- all software tests/builds/analysis/scenes/negative controls pass;
- artifact validator passes;
- exit `2` with the exact documented performance-pending message unless
  physical profiles are supplied.

Any other nonzero status is a failure and must be fixed before handoff.

- [ ] **Step 8: Perform manual Brush Lab review**

Launch the app and run the generated manual cards. Record the user's assessment
without changing renderer code or expected images during the review.

If the user approves a brush's current appearance, promote only that brush's
candidate baseline in a separate explicit commit. Unapproved brushes remain
manual-quality pending; no baseline is silently created.

- [ ] **Step 9: Complete and commit the milestone**

Record:

- exact commits;
- tests/suites;
- scene/negative counts;
- build/analyze commands;
- artifact root and manifest;
- software budgets;
- hardware-pending profiles;
- manual approvals still pending or completed;
- intentional removal of old parity and bounded wash;
- explicit Stage 5/Stage 6 boundary.

Commit only the evidence record and any explicitly approved baseline:

```bash
git add docs/superpowers/milestones/11-brush-deposition-backend.md
git commit -m "docs(brush): record Stage 4 evidence"
```

- [ ] **Step 10: Re-run gate on the final commit**

Run the exact clean committed gate again. The milestone may name only this
final commit/evidence bundle.

---

## Final Review And Completion

After Task 12:

1. Run the Superpowers whole-branch review against the commit preceding Task 1.
2. Fix Critical/Important findings through one reviewed fix wave.
3. Re-run `./scripts/verify-brush-stage4.sh` on the final commit.
4. Confirm `git status --short` contains only the pre-existing `.vscode/`.
5. Present the software result, hardware-pending status, and manual card list
   to the user.
6. Do not claim Stage 4 complete until every software gate passes and the user
   has assessed the manual cards. Hardware-only gates may remain explicitly
   pending exactly as the design permits.

## Plan Completion Boundary

This plan is accepted for execution only after the user reviews both:

- `docs/superpowers/specs/2026-07-28-brush-deposition-backend-design.md`
- `docs/superpowers/plans/2026-07-28-brush-deposition-backend.md`

Implementation does not begin before that combined approval.
