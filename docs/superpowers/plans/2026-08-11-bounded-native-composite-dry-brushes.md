# Bounded Native Composite Dry Brushes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hard-cut native brush definitions to schema 3 and support exactly
one or two ordered dry components whose coverage, placement, dynamics, color,
material, taper, resources, emission cadence, and deterministic random streams
remain independent through compilation, stroke generation, cursor evaluation,
projection, sparse tiled deposition, erase, symmetry, history, and budgets.

**Architecture:** `BrushDefinition` keeps stroke-wide identity, capabilities,
stabilization, replay, termination, seed, limits, performance intent, and
compatibility metadata at the root. It encodes an explicit required
composition declaration and an ordered array of one or two
`BrushComponentDefinition` values. Each component has a stable identifier and
explicit contiguous ordinal. `BrushProgram` compiles root policy once and a
fixed primary/optional-secondary pair of component programs. The public
`BrushStrokeGenerator` remains the coordinator-facing value type; its current
single-brush state machine becomes a private component engine, and the root
generator advances both engines from each same authoritative sample without
retained-stroke replay. Global output ordinals remain contiguous for queues and
history, while every dab also carries stable component ordinal and
component-local ordinal. Metal compilation produces fixed one/two component
resource bundles. Sparse tile encoding preserves source-over semantics by
scanning each tile's already-stable record order into contiguous component
binding runs; it never globally regroups records by component.

**Tech Stack:** Swift 6, Swift Testing, PatternEngine, BrushFormat,
MetalRenderer, Metal deposition ABI 2, package-manifest schema 2, native brush
definition schema 3.

## Global Constraints

- Continue in the shared dirty `main` checkout and preserve every unrelated
  modification, including `.vscode/` and
  `brushes/procreate/1_FREE_Charcoal_Set.key`.
- Do not stage, commit, push, create a branch, or create a pull request.
- Native definition schema 3 is the sole accepted native definition version
  after this cutover. Schemas 1 and 2 are rejected; do not add a decoder,
  migration DTO, adapter, alias, fallback, or compatibility branch for them.
- Keep native package-manifest schema 2 exact-current. Its wire layout does not
  change. `BrushPackage` requires a schema-3 definition payload.
- Keep deposition shader ABI 2 unless an actual shader-buffer layout changes.
  Component identity stays in CPU-side logical/projected records and does not
  justify an ABI bump by itself.
- Existing source-code single-component constructors may remain as schema-3
  conveniences that construct one real component. They must not decode or
  model an older schema and must encode only the schema-3 component layout.
- Remove singular definition storage and consumer aliases. Runtime code must
  choose an explicit component; a computed `definition.coverage` or similar
  primary-component escape hatch would hide incomplete composite handling.
- Preserve exact schema-3 single-component raster output and the existing
  seven-word compatibility random cursor. Component ordinal zero keeps the
  existing stroke seed and logical-dab address; secondary components receive a
  separately derived nonzero seed namespace.
- Interpret the stable logical sample/dab identity used by random channels as
  the component engine's append-only local dab ordinal. Raw input events are
  not a valid random address because interpolation and timed emission can
  produce zero or many logical dabs per event.
- Composition identifier `native.ordered-source-over` means: for each accepted
  input sample, append primary-component output in its local order, then
  secondary-component output in its local order; encode those global records
  in exactly that order with source-over/load semantics. Never sort or batch
  across a component boundary if doing so changes that order.
- Schema 3 supports only dry deposition components: every component must use
  `BrushInteractionMode.none`. Destination-sampling/canvas-interaction brushes
  remain unavailable and are not flattened into this model.
- `LogicalDabBatch.maximumDabCount`, frame pending limits, replay dab limits,
  and projected-instance limits count aggregate output across components, not
  a per-component allowance. Resident-byte limits count the aggregate unique
  resource set.
- No pointer-input/frame-path allocation, unbounded collection, component
  metatype, callback registry, dynamic loader, or retained-stroke replay may be
  introduced.

---

### Task 1: Define the schema-3 component wire model and hard version boundary

**Files:**

- Create: `Sources/PatternEngine/BrushModel/BrushComponentDefinition.swift`
- Modify: `Sources/PatternEngine/BrushModel/BrushDefinition.swift`
- Modify: `Tests/PatternEngineTests/BrushDefinitionTests.swift`
- Modify: `Tests/PatternEngineTests/NativeBrushTestSupport.swift`

**Interfaces:**

- Produces `BrushComponentIdentifier`, `BrushComponentDefinition`,
  `BrushCompositionModeDeclaration`, and the known
  `native.ordered-source-over` identifier.
- Replaces singular root fields with `composition` and `components` in the
  schema-3 coding keys.
- Validates explicit ordinals `[0]` or `[0, 1]`, unique nonempty portable
  identifiers, one/two component count, per-component dry material, and all
  existing per-component constraints.

- [x] **Step 1: Write schema-3 RED tests**

  Add literal JSON and constructor tests proving:

  - schema 3 round-trips one component and two independently populated
    components with the exact `composition` and `components` keys;
  - the old singular `coverage`, `placement`, `dynamics`, `color`, `material`,
    `taper`, `resources`, `sensorProgram`, `emission`, and `tipSupports` keys do
    not appear in encoded root JSON;
  - version 1, version 2, and future-version envelopes throw
    `.unsupportedSchemaVersion` before any DTO fallback;
  - zero components, three components, duplicate identifiers, empty/unsafe
    identifiers, duplicate ordinals, non-contiguous ordinals, and non-dry
    component material throw stable typed validation errors;
  - two components may share an exactly equal resource reference, while a
    repeated identifier with different hash/kind metadata throws a typed
    conflicting-resource error;
  - changing only component order/ordinal changes equality and encoded bytes.

- [x] **Step 2: Run the focused tests and verify RED**

  Run:

  ```bash
  swift test --filter BrushDefinitionTests
  ```

  Expected: compilation fails because the component/composition types and
  schema-3 layout do not exist.

- [x] **Step 3: Implement the minimal schema-3 domain**

  Define a component with these owned values:

  ```swift
  public struct BrushComponentDefinition: Codable, Equatable, Sendable {
      public let identifier: BrushComponentIdentifier
      public let ordinal: UInt8
      public let resources: [BrushResourceReference]
      public let coverage: BrushCoverageDefinition
      public let placement: BrushPlacementDefinition
      public let dynamics: BrushDynamicsDefinition
      public let color: BrushColorBehaviorDefinition
      public let material: BrushMaterialDefinition
      public let taper: BrushTaperConfiguration
      public let sensorProgram: BrushSensorProgramDefinition
      public let emission: BrushEmissionDefinition
      public let tipSupports: [BrushTipSupportDefinition]
  }
  ```

  Keep sensor normalization, stabilization v1/v2, direction, replay,
  termination, limits, and seed policy at the root. Set
  `BrushDefinition.currentSchemaVersion` to `3`. Rename the private decoder to
  `BrushDefinitionV3DTO`; it must decode only schema 3. Move existing validation
  helpers to validate each component and prefix diagnostic field names with
  `components.<ordinal>.`.

  Provide a source-only single-component convenience initializer with the
  current call signature. It constructs component identifier `primary`,
  ordinal `0`, and the required ordered-source-over declaration; it is not a
  legacy adapter and has no schema argument.

- [x] **Step 4: Run focused tests and verify GREEN**

  Run `swift test --filter BrushDefinitionTests` and confirm all schema/domain
  tests pass.

---

### Task 2: Compile fixed component programs and explicit composition semantics

**Files:**

- Modify: `Sources/PatternEngine/BrushModel/BrushProgram.swift`
- Modify: `Sources/PatternEngine/BrushModel/BrushProgramCompiler.swift`
- Modify: `Sources/PatternEngine/BrushDynamicsEngine.swift`
- Modify: `Sources/MetalRenderer/BrushBackend/BrushBackendRegistry.swift`
- Modify: `Sources/MetalRenderer/BrushBackend/BrushBackendCompiler.swift`
- Modify: `Tests/PatternEngineTests/BrushProgramCompilerTests.swift`
- Modify: `Tests/PatternEngineTests/BrushDynamicsEngineTests.swift`
- Modify: `Tests/MetalRendererTests/BrushBackendRegistryTests.swift`

**Interfaces:**

- Adds `BrushComponentProgram` with definition, component ordinal, compiled
  Stage-C sensor program, and component emission metadata.
- Makes `BrushProgram` expose fixed `primaryComponent` and optional
  `secondaryComponent`, plus compiled `.orderedSourceOver` composition.
- Replaces `BrushBackendRegistry.nativeSchema2` with exact
  `BrushBackendRegistry.nativeSchema3` rows.

- [x] **Step 1: Write composition/program RED tests**

  Prove:

  - one/two component definitions compile in declared ordinal order and retain
    different sensor programs, spacing, emission modes, taper, and material;
  - missing/unknown required composition identifiers throw
    `.unknownRequiredCompositionMode` before activation;
  - an unknown optional identifier cannot become executable accidentally and
    throws `.unsupportedCompositionMode` rather than selecting a default;
  - required capabilities remain root-wide, but dry/material and conservative
    secondary-color capability validation runs for every component and reports
    the first component ordinal deterministically;
  - registry schema 3 resolves deposition/canvas rows, while real native
    schema 2 fails exact lookup;
  - dynamics evaluation consumes the selected component program and never
    reads a root singular field.

- [x] **Step 2: Run the compiler filters and verify RED**

  ```bash
  swift test --filter 'BrushProgramCompilerTests|BrushDynamicsEngineTests|BrushBackendRegistryTests'
  ```

- [x] **Step 3: Implement component program compilation**

  Compile root capabilities/termination/composition once. Compile each
  component's sensor table, taper, placement, coverage, material, emission, and
  tip support into `BrushComponentProgram`. Store a primary value and optional
  secondary value so hot code does not allocate an array or dynamically
  dispatch a component.

  Make backend activation validate all component materials and semantic
  outputs before package/resource work. Atomically rename the closed registry
  literal to `nativeSchema3` and register only exact schema 3. Do not retain a
  deprecated `nativeSchema2` alias.

- [x] **Step 4: Run focused tests and verify GREEN**

  Run the Step 2 filter and confirm typed composition and exact registry tests
  pass.

---

### Task 3: Add deterministic component-local identity and random namespaces

**Files:**

- Modify: `Sources/PatternEngine/BrushRandom.swift`
- Modify: `Sources/PatternEngine/BrushModel/LogicalDabBatch.swift`
- Modify: `Sources/PatternEngine/BrushDynamicsEngine.swift`
- Modify: `Tests/PatternEngineTests/BrushRandomTests.swift`
- Modify: `Tests/PatternEngineTests/BrushDynamicsEngineTests.swift`
- Modify: `Tests/PatternEngineTests/BrushStrokeGeneratorTests.swift`

**Interfaces:**

- Adds `componentOrdinal` and `componentDabOrdinal` to `LogicalDab` while
  retaining global `ordinal` as the queue/history identity.
- Adds `BrushComponentRandomNamespace` with deterministic nonzero seed
  derivation for component ordinal 1; ordinal 0 returns the root stroke seed
  unchanged.

- [x] **Step 1: Write identity/random RED tests**

  Add literal vector tests proving:

  - component zero's compatibility words and extension/sensor-term random
    values are byte-for-byte identical to current single-component vectors;
  - component one receives a different nonzero seed, is repeatable, and does
    not consume or perturb component zero's cursor;
  - changing collection/evaluation order does not change either component's
    values when addressed by root seed, component ordinal,
    component-dab ordinal, and channel;
  - a `LogicalDabBatch` still requires contiguous global ordinals but permits
    interleaved component ordinals and independently monotonic local ordinals;
  - duplicate/skipped component-local ordinals within a component are rejected
    by the composite generator boundary, not confused with global continuity.

- [x] **Step 2: Run focused tests and verify RED**

  ```bash
  swift test --filter 'BrushRandomTests|BrushDynamicsEngineTests|BrushStrokeGeneratorTests'
  ```

- [x] **Step 3: Implement stable addresses**

  Keep `BrushRandom`'s seven-word sequence unchanged. Derive only secondary
  component seed state with a fixed documented SplitMix64 domain constant and
  force the result nonzero. Counter-based extension and sensor-term randomness
  use the component seed plus the component-local logical ordinal and existing
  permanent channel IDs. Add a checked helper that copies an evaluated
  component dab into its accepted global identity only after the outer sink
  accepts it.

- [x] **Step 4: Run focused tests and verify GREEN**

  Run the Step 2 filter and record the unchanged component-zero random vectors.

---

### Task 4: Turn BrushStrokeGenerator into a bounded composite coordinator

**Files:**

- Create: `Sources/PatternEngine/CompositeBrushStrokeGenerator.swift`
- Modify: `Sources/PatternEngine/BrushStrokeGenerator.swift`
- Modify: `Sources/PatternEngine/TimedStrokeEmitter.swift`
- Modify: `Sources/PatternEngine/TransientStrokeBuffer.swift`
- Modify: `Tests/PatternEngineTests/BrushStrokeGeneratorTests.swift`
- Modify: `Tests/PatternEngineTests/TransientStrokeBufferTests.swift`
- Modify: `Tests/PatternEngineTests/StageCAcceptancePartitionTests.swift`

**Interfaces:**

- Extracts the current implementation into an internal
  `BrushComponentStrokeGenerator` driven by one `BrushComponentProgram`.
- Keeps public `BrushStrokeGenerator` and its resumable cursor API as the
  fixed one/two component coordinator used by all existing snapshots.

- [x] **Step 1: Write independent-emission RED tests**

  Cover:

  - same authoritative samples produce different component-local spacing,
    timed/distance emission, size, flow, scatter, rotation, taper, and empty
    output exactly from each component's own program;
  - output order is primary dabs then secondary dabs for each input operation,
    with contiguous global ordinals and independent local ordinals;
  - a sink pause at every possible accepted-dab boundary resumes without
    duplicate random consumption, ordinal gaps, or reordered components;
  - predicted evaluation copies both engines and leaves authoritative state
    unchanged;
  - estimated-input replacement and replay-tail snapshots reproduce the same
    global/component identities without generating the secondary by replaying
    retained stroke history;
  - ended/reset/overflow/cancellation paths reset or reject both engines
    atomically;
  - a single-component schema-3 trace equals the current semantic and raster
    characterization anchors.

- [x] **Step 2: Run generator tests and verify RED**

  ```bash
  swift test --filter 'BrushStrokeGeneratorTests|TransientStrokeBufferTests|StageCAcceptancePartitionTests'
  ```

- [x] **Step 3: Implement fixed composite orchestration**

  The root cursor owns primary cursor state, optional secondary cursor state,
  current component phase, and next global ordinal. For each input, advance the
  primary component to completion, then the secondary, using the same immutable
  `WorldStrokeSample`. Tag a candidate with its component-local identity, offer
  it to the outer sink, and increment the global ordinal only on acceptance.
  Charge every component cursor step and every accepted dab to the existing
  resume work counter. Cap aggregate accepted output at
  `LogicalDabBatch.maximumDabCount` per page.

  Do not build `[generator]`, `[cursor]`, closures, or temporary dab arrays in
  the hot path. Use fixed primary and optional-secondary stored properties.

- [x] **Step 4: Run generator/lifecycle tests and verify GREEN**

  Run the Step 2 filter and confirm single-component anchors did not change.

---

### Task 5: Carry component identity through coordinator, projection, budgets, and transforms

**Files:**

- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokeRenderCoordinator.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokeFrameScheduler.swift`
- Modify: `Sources/MetalRenderer/Deposition/DepositionStampInstance.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/GridRenderer+Harness.swift`
- Modify: `Sources/PatternEngine/BrushTerminationEvaluator.swift`
- Modify: `Tests/MetalRendererTests/StrokeRenderCoordinatorTests.swift`
- Modify: `Tests/MetalRendererTests/StrokeFrameSchedulerTests.swift`
- Modify: `Tests/MetalRendererTests/DepositionStampInstanceTests.swift`
- Modify: `Tests/MetalRendererTests/DepositionRendererTests.swift`

**Interfaces:**

- Adds `componentOrdinal` to `ProjectedDepositionRecord` and
  `StrokePreparedProjectedRecord` without changing the packed Metal instance
  ABI.
- Keeps coordinator queues and history keyed by contiguous global ordinal.

- [x] **Step 1: Write propagation/budget RED tests**

  Prove component identity survives authoritative, predicted, replay,
  projection, tiling, periodic, reflected, and radial paths. Add tests that
  aggregate two-component output hits existing per-page, per-frame pending,
  replay-dab, projected-instance, dirty-region, tile-reference, and work-unit
  ceilings. A two-component definition must not double any ceiling implicitly.

  Add mutation-sensitive geometry tests: draw and erase produce the same
  component transforms/bounds; symmetry and radial projection transform the
  complete component dab; history commit/undo/redo preserves canonical pixels
  without needing to replay component generators.

- [x] **Step 2: Run focused runtime tests and verify RED**

  ```bash
  swift test --filter 'StrokeRenderCoordinatorTests|StrokeFrameSchedulerTests|DepositionStampInstanceTests|DepositionRendererTests'
  ```

- [x] **Step 3: Propagate identity without changing lifecycle ownership**

  Thread the CPU-side component ordinal through projection and prepared record
  types. Preserve global identity for queue discontinuity checks, prediction
  provenance, transient replacement, and history. Count all component-expanded
  dabs/instances/work using the existing aggregate counters. Keep
  `PatternDepositionStampInstance` layout and `DepositionABI.version == 2`.

- [x] **Step 4: Run focused runtime tests and verify GREEN**

  Run the Step 2 filter.

---

### Task 6: Compile fixed one/two component GPU resources and aggregate residency

**Files:**

- Modify: `Sources/MetalRenderer/BrushCompiler/CompiledBrush.swift`
- Modify: `Sources/MetalRenderer/BrushCompiler/BrushCompiler.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokeRenderState.swift`
- Modify: `Sources/MetalRenderer/BrushCompiler/BrushResourceCache.swift`
- Modify: `Sources/MetalRenderer/BrushCompiler/BrushMaskCache.swift`
- Modify: `Tests/MetalRendererTests/BrushCompilerTests.swift`
- Modify: `Tests/MetalRendererTests/BrushMaskCacheTests.swift`
- Modify: `Tests/MetalRendererTests/BrushTextureTests.swift`

**Interfaces:**

- Adds immutable `CompiledBrushComponent` and
  `CompiledBrushRenderComponentResources` values containing component ordinal,
  identifier, pipeline key/binding, uniform template, material binding,
  textures, tip supports, and cursor profile.
- Makes root compiled/render state fixed primary plus optional secondary and
  reports aggregate unique resident bytes.

- [x] **Step 1: Write compiler/resource RED tests**

  Assert:

  - each component independently selects function constants, pipeline,
    material uniforms, shapes, grains, and cursor profile;
  - equal cross-component resource references share decode/upload/cache
    identity and count resident bytes once;
  - conflicting same-ID references fail before decode/upload/cache mutation;
  - combined unique resources are rejected when their aggregate bytes exceed
    the root limit, even if each component alone fits;
  - failed secondary compilation leaves the previous active brush/cache and
    every compiler counter unchanged;
  - compiled component order exactly matches definition order.

- [x] **Step 2: Run compiler filters and verify RED**

  ```bash
  swift test --filter 'BrushCompilerTests|BrushMaskCacheTests|BrushTextureTests'
  ```

- [x] **Step 3: Compile components transactionally**

  Preflight the union of component references deterministically, allowing an
  identical shared reference but rejecting an identifier conflict. Decode and
  cache each unique resource once. Compile each component's pipeline/material
  from its own program and bindings into fixed root storage. Sum unique
  resident bytes before activation. On any failure, roll back the whole
  candidate exactly as current single-brush compilation does.

- [x] **Step 4: Run compiler filters and verify GREEN**

  Run the Step 2 filter.

---

### Task 7: Preserve authored source-over order in deposition and sparse tiles

**Files:**

- Modify: `Sources/MetalRenderer/Deposition/DepositionEncoder.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokePrivateSurfaceEncoder.swift`
- Modify: `Sources/MetalRenderer/StrokeRuntime/StrokeTileSurfaceResources.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Tests/MetalRendererTests/DepositionEncoderTests.swift`
- Modify: `Tests/MetalRendererTests/StrokeTileSurfaceEncoderTests.swift`
- Modify: `Tests/MetalRendererTests/PredictionOverlayTests.swift`
- Modify: `Tests/MetalRendererTests/DocumentPaintStableSnapshotRendererTests.swift`

**Interfaces:**

- Replaces one fixed pipeline/material/texture binding in stroke encoding with
  fixed primary and optional-secondary binding bundles.
- Encodes contiguous component runs in existing stable record order.

- [x] **Step 1: Write ordered-run RED tests**

  Use distinguishable component colors/materials/pipelines to prove:

  - record order `0, 0, 1, 1, 0` yields exactly three binding runs, not two
    globally grouped draws;
  - reversing definition component order changes source-over pixels where
    alpha overlaps;
  - splitting a run at upload/tile/page boundaries produces the same pixels as
    an unsplit run;
  - prediction replacement, authoritative continuation, erase, periodic,
    reflected, radial, clear/load, failure rollback, lease ACK, and cancellation
    retain current atomicity;
  - component identity never selects an out-of-range binding;
  - warmed two-component tile encoding allocates zero bytes on the measured
    preparation/submission path.

- [x] **Step 2: Run encoder filters and verify RED**

  ```bash
  swift test --filter 'DepositionEncoderTests|StrokeTileSurfaceEncoderTests|PredictionOverlayTests|DocumentPaintStableSnapshotRendererTests'
  ```

- [x] **Step 3: Implement bounded contiguous binding runs**

  Remove the brush pipeline from `StrokeTileSurfaceResources`; it is a generic
  surface/upload workspace. Validate rgba16Float for every component binding
  when installing `StrokeTileEncodingConfiguration`. Keep the stable tile
  partition's reference order. For each tile range, scan adjacent references
  for equal component ordinal, bind that component's pipeline/material/four
  textures, and draw only that contiguous subrange before continuing. The
  maximum run count is bounded by the existing tile-reference count and needs
  no allocated run array.

  Give standalone `DepositionEncoder` the same prepared ordered-run model; its
  single-component convenience delegates to one real run. Do not issue one
  pass per component over the whole record set.

- [x] **Step 4: Run encoder filters and verify GREEN**

  Run the Step 2 filter and retain the shader ABI/layout tests unchanged.

---

### Task 8: Evaluate and render the conservative union cursor

**Files:**

- Modify: `Sources/PatternEngine/BrushCursorDescriptor.swift`
- Modify: `Sources/MetalRenderer/BrushCompiler/CompiledBrush.swift`
- Modify: `App/PatternSpike/Canvas/InteractiveMetalView.swift`
- Modify: `Sources/BrushInputAllocationProbeHarness/main.swift`
- Modify: `Tests/PatternEngineTests/BrushCursorDescriptorTests.swift`
- Modify: `App/Tests/BrushCursorIntegrationTests.swift`

**Interfaces:**

- Adds `BrushCursorComponentDescriptor` for one component's existing
  primary/secondary shape support.
- Makes root `BrushCursorDescriptor` contain one/two ordered component
  descriptors and union their core/envelope bounds and occupancy.

- [x] **Step 1: Write cursor-union RED tests**

  Prove the descriptor uses each component's own compiled dynamics, tip
  profile, shape combination, maximum placement jitter, and deformation. Test
  disjoint, nested, empty-contribution, secondary-shape, pressure/tilt, and
  two-component circle cases. Root bounds and `containsCore` must be the union;
  `isCircle` is true only for one circular visible component. App integration
  must draw every component layer and size accessibility support from the root
  envelope.

- [x] **Step 2: Run cursor filters and verify RED**

  ```bash
  swift test --filter 'BrushCursorDescriptorTests|BrushCursorIntegrationTests'
  ```

- [x] **Step 3: Implement fixed cursor component evaluation**

  Reuse the existing within-component primary/secondary composition code for
  each component program/profile, then union component bounds/containment at
  the root. Update macOS cursor drawing to iterate the at-most-two components
  and their internal shape layers in declared order. Preserve the existing
  non-interactive overlay, backing-scale math, and allocation evidence.

- [x] **Step 4: Run cursor filters and verify GREEN**

  Run the Step 2 filter.

---

### Task 9: Migrate package/hash/producers atomically to schema 3

**Files:**

- Modify: `Sources/BrushFormat/BrushContentHash.swift`
- Modify: `Sources/BrushFormat/BrushPackage.swift`
- Modify: `Sources/BrushFormat/BrushPackageCodec.swift`
- Modify: `Sources/BrushConverter/SyntheticV1BrushMapper.swift`
- Modify: `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift`
- Modify: `Sources/EditorCore/Brushes/StageFourAnchorDefinitions.swift`
- Modify: `App/PatternSpike/BrushLab/BrushLabSession.swift`
- Modify: `Sources/MetalRenderer/Capture/DepositionHarnessRunner.swift`
- Modify: `Sources/MetalRenderer/GridRenderer+Harness.swift`
- Modify: `Sources/BrushInputAllocationProbeHarness/main.swift`
- Modify: every in-tree source/test factory that constructs or inspects a
  native brush definition
- Modify: `Tests/BrushFormatTests/BrushContentHashTests.swift`
- Modify: `Tests/BrushFormatTests/BrushPackageCodecTests.swift`
- Modify: `Tests/BrushConverterTests/SyntheticV1BrushMapperTests.swift`
- Modify: `Tests/EditorCoreTests/ProfessionalBrushCatalogTests.swift`

**Interfaces:**

- Bumps the semantic content-hash writer version to 4 and serializes root
  composition plus every component field in declared order.
- Keeps package-manifest schema 2 and requires definition schema 3.
- Makes all foreign/current producers emit schema-3 values directly.

- [x] **Step 1: Write package/hash/producer RED tests**

  Assert literal single/two-component hashes, order sensitivity, shared
  resource handling, package-manifest version 2, definition version 3, and
  typed schema-1/2 definition rejection. Decode malicious packages whose
  manifest is current but payload is old; they must not enter compilation.
  Verify the Synthetic external token `bounded-wash` remains an external
  material token and is not confused with the retired native recipe ID.

- [x] **Step 2: Run format/producer filters and verify RED**

  ```bash
  swift test --filter 'BrushContentHashTests|BrushPackageCodecTests|SyntheticV1BrushMapperTests|ProfessionalBrushCatalogTests'
  ```

- [x] **Step 3: Perform the hard producer cutover**

  Serialize each component identifier, ordinal, resource references, coverage,
  placement, dynamics, color, material, taper, sensor program, emission, and
  tip supports in order. Delete schema-2 hash tags/writers; do not branch by
  native definition version. Keep manifest codec at exact schema 2. Update
  every built-in, editor, converter, harness, allocation-probe, and test
  producer to construct schema 3 directly, using the single-component
  convenience only where the brush is genuinely singular.

- [x] **Step 4: Run format/producer filters and verify GREEN**

  Run the Step 2 filter, then run:

  ```bash
  rg -n 'nativeSchema2|BrushDefinitionV2DTO|schemaVersion[^\n]*2' Sources Tests App
  ```

  Inspect every remaining hit. Package-manifest schema 2 and deposition ABI 2
  are expected; native definition/backend schema-2 code is not.

---

### Task 10: Add composite functional, raster, and performance acceptance

**Files:**

- Create: `Tests/PatternEngineTests/CompositeBrushStrokeGeneratorTests.swift`
- Create: `Tests/MetalRendererTests/CompositeBrushFunctionalTests.swift`
- Modify: `Sources/MetalRenderer/Capture/DepositionHarnessRunner.swift`
- Modify: `Tests/MetalRendererTests/DepositionHarnessRunnerTests.swift`
- Modify: `Tests/PatternEngineTests/BrushCharacterizationTests.swift`
- Modify: `Tests/EditorCoreTests/AnchorBrushCharacterizationTests.swift`
- Modify: `Sources/BrushInputAllocationProbeHarness/main.swift`
- Modify: `Tests/Baselines/README.md`

**Interfaces:**

- Adds a project-owned two-component dry fixture with visibly distinct spacing,
  dynamics, resources, and alpha/color contribution.
- Extends production harness/allocation evidence to the maximum component
  count.

- [x] **Step 1: Add vertical-slice acceptance tests**

  Cover all Task 18 requirements in production paths:

  - independent spacing/dynamics and component contribution;
  - authored component order/source-over;
  - random isolation and collection-order independence;
  - draw/erase geometry identity;
  - cursor union versus raster support;
  - plain, periodic, reflected, radial, and maximum-symmetry transforms;
  - empty primary/secondary output;
  - undo/redo canonical pixels;
  - aggregate dab/work/tile/reference/resident-byte failures;
  - single-component semantic/raster anchors unchanged;
  - two-component deterministic raster digest.

  Add negative controls that intentionally share one random cursor, globally
  regroup component records, replay retained samples for the secondary,
  allocate a component array on the hot path, and omit the secondary from
  bounds/resource budgets. Each control must fail its specific gate.

- [x] **Step 2: Run the composite functional gate**

  ```bash
  swift test --filter 'CompositeBrushStrokeGeneratorTests|CompositeBrushFunctionalTests|BrushCharacterizationTests|AnchorBrushCharacterizationTests'
  ```

- [x] **Step 3: Run release allocation/performance evidence**

  Build release and run the existing allocation probe with the new maximum
  component scenario. Confirm zero warmed input/frame-path allocations, no
  retained-stroke replay, bounded preparation work, bounded pending output,
  aggregate resident bytes within declared limits, and no regression in the
  existing single-component 10-second/accelerated traces.

- [x] **Step 4: Run the deposition harness gate**

  ```bash
  swift test --filter DepositionHarnessRunnerTests
  ```

  Require both the current single-component scene matrix and new composite
  positive/negative scenes to pass.

---

### Task 11: Full verification, independent review, and checkpoint

**Files:**

- Create:
  `.superpowers/sdd/2026-08-01-brush-engine-corrective-program/task-18-bounded-native-composite-dry-brushes-checkpoint.md`
- Modify:
  `.superpowers/sdd/2026-08-01-brush-engine-corrective-program/progress.md`
- Modify: this plan to mark every completed step
- Modify:
  `docs/superpowers/plans/2026-08-01-brush-engine-corrective-program.md`
  only to check completed Task 18 items
- Modify:
  `docs/superpowers/plans/2026-08-10-native-current-only-cleanup.md`
  only to check the hard-cut amendment items

- [x] **Step 1: Run clean full verification from current sources**

  Run:

  ```bash
  swift test
  swift build -c release
  git diff --check
  git diff --cached --name-only
  ```

  Require zero test/build failures, a clean whitespace check, and no staged
  files. Also inspect production source for schema-2 native branches, singular
  definition aliases, global component regrouping, dynamic backend loading,
  unbounded component storage, and retained-stroke replay.

- [x] **Step 2: Request scoped independent review**

  Review the complete Task 18 diff against this plan and the approved master
  requirements. Require explicit attention to:

  - schema 3 only / no v1-v2 adapter;
  - exact package-manifest schema 2 and deposition ABI 2 boundaries;
  - component-zero raster/random compatibility;
  - independent resampling/randomness and pause/resume causality;
  - aggregate limits and no allocations;
  - source-over binding-run order;
  - prediction/replay/cancellation atomicity;
  - erase/cursor/history/tiling/radial completeness.

- [x] **Step 3: Apply review feedback with TDD and re-run affected/full gates**

  Reproduce every accepted issue with a failing test, make the minimal fix,
  re-run the focused filter, then repeat Step 1. Do not treat an unresolved
  Critical or Important finding as complete.

- [x] **Step 4: Write the Task 18 checkpoint**

  Record exact changed interfaces, typed rejection behavior, unchanged
  single-component anchors, composite raster digest, performance/allocation
  evidence, test counts/timings, review outcome, remaining external acceptance
  blockers, dirty-tree/no-stage status, and the fact that no commit/push/PR was
  made.
