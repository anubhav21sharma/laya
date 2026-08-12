# Compile-Time Brush Backend Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace BrushCompiler's deposition-only conditionals with one immutable, deterministic registry that resolves exact native schema/backend pairs, produces a typed compiled backend contract, and rejects unavailable execution or unimplemented color-source semantics before any resource or GPU work.

**Architecture:** `MetalRenderer.BrushBackendRegistry` is a sorted immutable table of pure value registrations keyed by `(BrushBackendKind, definitionSchemaVersion)`. Registrations name compiler and encoder families, declared/implemented capability bitsets, and activation availability; they never contain closures, class names, dynamic libraries, or package-provided executable code. `BrushBackendCompiler` resolves a validated `BrushProgram` through that table, builds a deposition or canvas-interaction contract, and centrally enforces retired native identifiers, backend support, deposition material limits, required semantics, and conservative secondary-color capability requirements. `BrushCompiler` consumes the resulting deposition contract before decode/upload and retains it in `CompiledBrush`; Task 18 can replace the schema-2 registry atomically with schema 3.

**Tech Stack:** Swift 6, Swift Testing, PatternEngine schema-2 brush programs, MetalRenderer deposition pipelines, existing typed `BrushCompilationFailure` diagnostics.

## Global Constraints

- Continue in the shared dirty `main` checkout; preserve every unrelated change.
- Do not stage, commit, push, or create a pull request.
- Register only exact native definition schema 2 in Task 17; schema 1 and schema 3 must not fall through.
- Keep the canvas-interaction/continuous-ribbon entry known but activation-internal until an encoder exists.
- Package content can select only an existing enum kind and numeric schema; it cannot supply code, lookup names, registrations, or dynamic libraries.
- Reject backend/semantic failures before incrementing decode/upload/cache/activation counters.
- Keep `secondaryColorMix` in PatternEngine and logical dabs; do not silently erase it to make deposition compile.
- Remove `usesDestinationSampling` from every deposition pipeline-key constructor and diagnostic serializer, not just the main compiler.

---

### Task 1: Immutable sorted registry domain

**Files:**

- Create: `Sources/MetalRenderer/BrushBackend/BrushBackendRegistry.swift`
- Create: `Tests/MetalRendererTests/BrushBackendRegistryTests.swift`

**Interfaces:**

- Consumes: `BrushBackendKind` and native definition schema versions.
- Produces: `BrushBackendRegistryKey`, compiler/encoder family enums, capability bitsets, immutable registrations, `BrushBackendRegistryError`, exact lookup, and `BrushBackendRegistry.nativeSchema2`.

- [x] **Step 1: Write failing duplicate, lookup, and ordering tests**

Name the breaks explicitly:

- two entries with the same `(kind, schema)` must throw `.duplicateRegistration` rather than silently choosing one;
- a missing kind must throw `.unknownBackend`, while a known kind at the wrong schema must throw `.unsupportedSchema` with literal sorted supported versions;
- entries supplied in reverse order must publish in deterministic `kind.rawValue`, then schema order;
- implemented capabilities must be a subset of declared capabilities;
- the native schema-2 table must contain the deposition and canvas-interaction/continuous-ribbon rows only, with deposition activatable and continuous ribbon internal-only.

Use hand-written registrations and literal expected keys/families. Do not derive expected order with the registry comparator.

- [x] **Step 2: Run the registry tests and verify RED**

Run:

```bash
swift test --filter BrushBackendRegistryTests
```

Expected: compilation fails because the registry types do not exist.

- [x] **Step 3: Implement the minimal value-only registry**

Define stable enums and bitsets along these lines:

```swift
public enum BrushBackendCompilerFamily: String, Sendable {
    case deposition
    case continuousRibbon
}

public enum BrushBackendEncoderFamily: String, Sendable {
    case instancedDeposition
    case continuousRibbon
}

public struct BrushBackendCapabilities: OptionSet, Sendable {
    public static let destinationSampling = Self(rawValue: 1 << 0)
    public static let secondaryColorSource = Self(rawValue: 1 << 1)
}
```

Each registration contains its exact key, families, declared and implemented capabilities, and `.available` or `.internalOnly` activation status. The public throwing initializer validates duplicates and capability consistency, then stores a private sorted array. Lookup uses that immutable array and distinguishes an absent kind from an unsupported version.

`nativeSchema2` contains:

- deposition/schema 2 -> deposition compiler + instanced deposition encoder, activation available;
- canvasInteraction/schema 2 -> continuous-ribbon compiler + encoder, destination-sampling declared in its contract, activation internal-only, with no secondary-color-source implementation.

Use a closed source literal for this table. Do not expose mutation, registration callbacks, metatypes, symbol names, or loader APIs.

- [x] **Step 4: Run the registry tests and verify GREEN**

Run:

```bash
swift test --filter BrushBackendRegistryTests
```

Expected: all registry construction, resolution, and order tests pass.

---

### Task 2: Typed backend contract compiler

**Files:**

- Create: `Sources/MetalRenderer/BrushBackend/BrushBackendCompiler.swift`
- Modify: `Sources/MetalRenderer/BrushCompiler/CompiledBrush.swift`
- Modify: `Tests/MetalRendererTests/BrushBackendRegistryTests.swift`

**Interfaces:**

- Consumes: an immutable registry, validated `BrushProgram`, definition schema, required semantic keys, material interaction/edge semantics, sensor-program output bounds, and color jitter.
- Produces: `CompiledBrushBackendContract`, deposition and canvas-interaction contract values, plus typed `BrushBackendCompilationError` cases.

- [x] **Step 1: Write failing contract and capability tests**

Add real program fixtures proving:

- a neutral schema-2 dry program compiles to `.deposition` with the registered families;
- a canvas-interaction program compiles to a contract whose `usesDestinationSampling` is true and whose family is continuous ribbon;
- requiring activation of that contract throws typed `.backendUnavailable` before resource work;
- a retired `builtin.bounded-wash` definition throws typed `.retiredNativeIdentifier` while current built-in IDs and arbitrary non-retired imported IDs resolve normally;
- nonempty required semantic keys fail with the first deterministic sorted key;
- deposition rejects unsupported interaction and wet-concentration material semantics;
- a secondary-color output whose conservative upper bound is positive, or whose per-stamp/per-stroke jitter can make it positive, throws `.missingImplementedCapability(.secondaryColorSource)`;
- an output that is provably zero through replace/add/multiply/minimum/maximum terms remains accepted.

Literal fixtures must independently exercise each response operation. The key mutation check is that deleting any term/jitter check makes at least one positive-use test pass incorrectly.

- [x] **Step 2: Run the backend compiler tests and verify RED**

Run:

```bash
swift test --filter BrushBackendRegistryTests
```

Expected: compilation fails because the backend compiler and contract types do not exist.

- [x] **Step 3: Implement backend contract compilation**

Create:

```swift
public enum CompiledBrushBackendContract: Equatable, Sendable {
    case deposition(CompiledDepositionBackendContract)
    case canvasInteraction(CompiledCanvasInteractionBackendContract)
}
```

Only the canvas-interaction case owns `usesDestinationSampling`. The deposition contract carries its compiler/encoder family but no destination-sampling bit.

`BrushBackendCompiler` performs, in order:

1. exact registry resolution for `program.requestedBackend` and `definition.schemaVersion`;
2. retired native-ID rejection (`builtin.bounded-wash` only; do not create an alias map);
3. deterministic required-semantic rejection;
4. backend-specific material validation;
5. capability validation;
6. contract construction and, when requested by activation, availability validation.

For `secondaryColorMix`, calculate a conservative interval from the validated sensor output: begin at `baseValue`; use each term's response clamp as its interval; apply replace/add/multiply/minimum/maximum interval arithmetic; clamp the final interval to `[0, 1]`; then expand by the absolute per-stamp and per-stroke secondary-color jitter. Any upper bound above zero requires `.secondaryColorSource` to be both declared and implemented. This is cold-path validation and may iterate the at-most-four terms.

- [x] **Step 4: Run the contract tests and verify GREEN**

Run:

```bash
swift test --filter BrushBackendRegistryTests
```

Expected: contract selection and every typed capability branch pass.

---

### Task 3: Route BrushCompiler activation through the registry

**Files:**

- Modify: `Sources/MetalRenderer/BrushCompiler/BrushCompiler.swift`
- Modify: `Sources/MetalRenderer/BrushCompiler/CompiledBrush.swift`
- Modify: `Tests/MetalRendererTests/BrushCompilerTests.swift`

**Interfaces:**

- Consumes: `BrushBackendRegistry.nativeSchema2`, `BrushBackendCompiler`, and compiled backend contracts.
- Produces: registry-backed early activation diagnostics and immutable `CompiledBrush.backendContract`.

- [x] **Step 1: Write failing activation-boundary tests**

Extend real `BrushCompiler` tests to assert:

- a compiled dry brush retains a deposition backend contract matching its pipeline backend;
- retired ID, unsupported registry version (using an injected test registry), unavailable continuous ribbon, required semantic, wet-concentration, and nonzero secondary-color cases all return `BrushCompilationFailure` at `.pipelineSelection` with stable typed-reason mapping;
- every failure leaves package-decode, image-decode, upload, cache-hit, and activation counters unchanged and preserves the previously active brush/cache;
- schema-2 deposition still prepares exactly the existing deposition binding.

Inject only the immutable registry. Keep the real semantic compiler and existing Metal test pipeline preparer; do not mock registry resolution.

- [x] **Step 2: Run focused compiler tests and verify RED**

Run:

```bash
swift test --filter 'BrushCompilerTests|BrushBackendRegistryTests'
```

Expected: new contract/diagnostic assertions fail against the old conditionals.

- [x] **Step 3: Integrate one early backend boundary**

Add a registry parameter to BrushCompiler's designated initializer, default convenience initializers to `.nativeSchema2`, and preserve it in staging compilers. After `BrushProgramCompiler.compile` and before `increment(.packageDecode)`, invoke the backend compiler for activation. Map each typed backend error once into `BrushCompilationFailure` at `.pipelineSelection`; delete `validateDepositionSupport`, the duplicated required-semantic guard, and the direct `requestedBackend == .deposition` guard.

Require the returned case to be deposition before constructing deposition materials/pipelines, and pass that exact contract into `CompiledBrush`. `inspectionReport` uses the same registry/compiler resolution without activation, so known internal continuous ribbon remains inspectable while unknown versions/retired IDs fail explicitly.

- [x] **Step 4: Run focused compiler tests and verify GREEN**

Run:

```bash
swift test --filter 'BrushCompilerTests|BrushBackendRegistryTests'
```

Expected: activation tests pass without resource/counter mutation on rejected programs.

---

### Task 4: Remove the false deposition destination-sampling dimension

**Files:**

- Modify: `Sources/MetalRenderer/BrushCompiler/CompiledBrush.swift`
- Modify: `Sources/MetalRenderer/BrushCompiler/BrushCompiler.swift`
- Modify: `Sources/MetalRenderer/Deposition/DepositionPipelineLibrary.swift`
- Modify: `Tests/MetalRendererTests/DepositionPipelineLibraryTests.swift`
- Modify: `Tests/MetalRendererTests/BrushCompilerTests.swift`
- Modify: all compile-required `BrushFunctionConstants` construction sites under `Sources/MetalRenderer` and `Tests/MetalRendererTests`
- Modify: `Sources/MetalRenderer/Capture/DepositionHarnessRunner.swift`

**Interfaces:**

- Consumes: the three Metal function constants actually used by deposition shaders.
- Produces: deposition keys whose identity varies only by real shader/pipeline semantics; destination sampling remains only on `CompiledCanvasInteractionBackendContract`.

- [x] **Step 1: Change tests first to express the real key dimensions**

Remove the fake destination-sampling variant from `DepositionPipelineLibraryTests`. Assert, with literal variants, that secondary shape, primary grain, secondary grain, accumulation, edge, ABI, pixel format, and sample count remain distinct. Update BrushCompiler tests to assert destination sampling on the canvas contract and its absence from `BrushFunctionConstants` by compiling against the new API, not by source scanning.

- [x] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter 'BrushBackendRegistryTests|BrushCompilerTests|DepositionPipelineLibraryTests'
```

Expected: compilation fails until the production function-constant API changes.

- [x] **Step 3: Delete the false field and update every real constructor**

Remove `usesDestinationSampling` from `BrushFunctionConstants`, compiler key creation, fallback/harness/test key builders, and capture-key serialization. Do not replace it with a hardcoded false field or another deposition cache-key bit. Leave `DepositionPipelineLibrary` backend validation intact and confirm its Metal constant binding still sets only the three coverage/grain booleans plus accumulation and edge values.

- [x] **Step 4: Run the prescribed focused gate**

Run:

```bash
swift test --filter 'BrushBackendRegistryTests|BrushCompilerTests|DepositionPipelineLibraryTests'
```

Expected: all selected suites pass.

---

### Task 5: Verification, review, and checkpoint

**Files:**

- Create: `.superpowers/sdd/2026-08-01-brush-engine-corrective-program/task-17-compile-time-backend-registry-checkpoint.md`
- Modify: `.superpowers/sdd/2026-08-01-brush-engine-corrective-program/progress.md`
- Modify: this plan to mark completed steps

**Interfaces:**

- Consumes: the final diff and fresh command output.
- Produces: Task 17 completion evidence and any review fixes.

- [x] **Step 1: Run focused and adjacent verification**

Run fresh:

```bash
swift test --filter 'BrushBackendRegistryTests|BrushCompilerTests|DepositionPipelineLibraryTests'
swift test --filter 'BrushProgramCompilerTests|BrushDynamicsEngineTests|DepositionMaterialBindingTests'
swift build -c release
git diff --check
```

Also inventory the final source for `usesDestinationSampling`, dynamic library loading, class-name lookup, and registry mutation APIs. The only destination-sampling production hit should be the compiled canvas-interaction contract; ordinary platform/library use elsewhere is not a backend plugin mechanism.

- [x] **Step 2: Request a scoped independent code review**

Review the Task 17 diff for Critical/Important/Minor findings, with special attention to:

- exact schema lookup and Task 18 atomic replacement;
- registry immutability and deterministic ordering;
- early-failure state/counter safety;
- conservative secondary-color interval arithmetic;
- no accidental executable-package or runtime-loader seam;
- no remaining deposition destination-sampling key dimension.

Fix every valid finding using a failing regression test first, then rerun the affected focused gate.

- [x] **Step 3: Write the checkpoint and update progress**

Record implemented behavior, tests, release build, review disposition, known external blockers, and the fact that no commit was created. Mark every completed checkbox in this plan and append Task 17 to the corrective-program progress ledger.

- [x] **Step 4: Continue directly to Task 18 preflight**

Inspect the approved composite-brush task, inventory current schema-2 producers/call sites, and write the Task 18 just-in-time implementation plan without waiting for intervention unless a genuine product decision cannot be derived from approved project context.
