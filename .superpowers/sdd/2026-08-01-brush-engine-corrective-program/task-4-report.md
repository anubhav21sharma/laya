# Task 4 — Make Stroke Termination Causal

## Result

Native dry-brush completion is now causal. A compiled native `.cap` or
`.pressureRelease` cannot request replacement of any previously deposited
ordinal, and `.boundedCorrection` can replace only a suffix that independently
fits its declared sample, world-length, and dab limits. The ordinary renderer
path no longer discovers total stroke length at pointer-up and re-evaluates the
retained body.

Technical Ink now retains no authoritative body dabs during the ten-second
corrective trace and its stabilized fast-release trace reaches the raw pointer
endpoint. The corresponding two Task 2 functional defects are green. The
unchanged Task 2 fixture remains intentionally red only for Graphite support,
Charcoal visibility, and Chisel turn quality: five issues remain, down from the
seven recorded at the Task 2 baseline.

Implementation baseline: `41f8ed5`.
Requested commit subject: `fix(brush): make stroke termination causal`.

## Requirement mapping

1. **Immutable termination model.**
   `BrushTerminationDefinition` is Codable and validates `.cap`,
   `.pressureRelease(maximumWorldLength:)`, and
   `.boundedCorrection(maximumSamples:maximumWorldLength:maximumDabs:)`.
   `BrushProgramCompiler` compiles it into an immutable
   `BrushTerminationProgram` before a stroke begins.
2. **Causal decisions.**
   `BrushTerminationEvaluator` returns append-only decisions for cap and
   pressure release; those decisions carry no ordinal range. Bounded correction
   returns a replacement range only after validating all three independent
   limits. Invalid correction metrics fail with typed errors.
3. **No native retained-body end taper.**
   Native dynamics evaluate start taper while a stroke is generated but never
   evaluate end taper from a total length learned later. `GridRenderer` obtains
   a known total distance and invokes retroactive taper only for the explicit
   adapter-only schema-v1 case. The former general
   `applyingKnownTotalDistance` entry point is gone.
4. **Exact native cap endpoint.**
   Native causal completion flushes the interpolator to the raw `.ended`
   coordinate instead of applying one more exponential stabilization step.
   This preserves all already emitted body dabs and fixes the product-equivalent
   Technical Ink endpoint retreat. Schema-v1 compatibility programs retain the
   old filtered release coordinate and have a frozen characterization test.
5. **Unforgeable schema-v1 compatibility boundary.**
   Public `BrushDefinition` initializers always create native definitions. An
   internal marker can be installed only by the named
   `LegacyBrushTerminationAdapter`, used by `LegacyBrushRecipeAdapter` and the
   schema-v1 decoder. Encoding a legacy definition omits the native termination
   field so decoding re-enters that named boundary; a public field-by-field
   rebuild encodes its native termination and cannot recover legacy taper.
6. **Replay-only schema-v1 compatibility.**
   Legacy replay contracts without an enabled end taper, including Bounded Wash
   and existing prediction/estimated-update compatibility fixtures, compile to
   a separate `legacySchemaV1Replay` case. This preserves their declared
   `replayTail` or `boundedWholeStroke` contract without granting native dry
   definitions retroactive end-taper behavior.
7. **Preserved legacy pixels.**
   Existing retained-boundary taper pixels remain exact through
   `legacySchemaV1EndTaper`. Legacy whole-stroke versus tail replay mode and
   replay limits survive compilation and Codable round trips unchanged.

## Files changed

- `Sources/PatternEngine/BrushRecipe.swift`
- `Sources/PatternEngine/BrushModel/BrushDefinition.swift`
- `Sources/PatternEngine/BrushModel/BrushProgram.swift`
- `Sources/PatternEngine/BrushModel/BrushProgramCompiler.swift`
- `Sources/PatternEngine/BrushModel/LegacyBrushRecipeAdapter.swift`
- `Sources/PatternEngine/BrushTerminationEvaluator.swift`
- `Sources/PatternEngine/BrushDynamicsEngine.swift`
- `Sources/PatternEngine/BrushStrokeGenerator.swift`
- `Sources/MetalRenderer/GridRenderer.swift`
- `Tests/PatternEngineTests/BrushDefinitionTests.swift`
- `Tests/PatternEngineTests/BrushDynamicsEngineTests.swift`
- `Tests/PatternEngineTests/BrushStrokeGeneratorTests.swift`
- `Tests/PatternEngineTests/BrushTerminationEvaluatorTests.swift`
- `Tests/EditorCoreTests/ProfessionalBrushDynamicsTests.swift`
- `.superpowers/sdd/2026-08-01-brush-engine-corrective-program/task-4-report.md`

The adapter, compiler, renderer, and professional-test files are necessary
dependent changes: they establish the non-forgeable compatibility boundary,
remove the actual product-path body re-evaluation, and replace obsolete
professional assertions that required retroactive taper.

## TDD evidence

### Initial model RED

Command:

```bash
swift test --filter 'Brush(Definition|DynamicsEngine|TerminationEvaluator)Tests'
```

Exit status: `1` as expected. The new tests failed to compile specifically
because the termination definition, compiled program, evaluator, decisions,
limit errors, and causal `BrushDefinition` field did not exist. No unrelated
test failure was present.

### Legacy mode preservation RED then GREEN

The new legacy whole-stroke test first failed because the initial implementation
forced every legacy taper to `replayTail`. After deriving the exact mode from
the marked definition, it passed. A second test then failed because a schema-v1
replay-only definition compiled as native append-only. The separate
`legacySchemaV1Replay` case made it green and restored the renderer replay
fixtures without reopening native end-taper replay.

### Stabilized cap RED then GREEN

Command:

```bash
swift test --filter stabilizedCapFlushesToRawReleasePointWithoutChangingBodyDabs
```

Before the endpoint fix, the final logical dab was at x=85 for a release at
x=120. After native causal completion bypassed terminal stabilization, the
same test passed at x=120 while its body prefix remained byte-for-byte equal.
The companion schema-v1 characterization still ends at the historical x=85.

## Verification evidence

### Required focused suite

```bash
swift test --filter 'Brush(Definition|DynamicsEngine|TerminationEvaluator)Tests'
```

Exit status: `0`; all focused definition, dynamics, termination-policy,
stabilized-endpoint, legacy-marker, and legacy-pixel tests passed: 34 tests in
zero suites.

### Adjacent PatternEngine and professional dynamics

```bash
swift test --filter 'Brush(StrokeGenerator|ProgramCompiler|Definition|DynamicsEngine|TerminationEvaluator)Tests|ProfessionalBrushDynamicsTests'
```

Exit status: `0`; 89 tests passed, including the final additive schema-v1
endpoint characterization.

### Renderer and metamorphic compatibility

```bash
swift test --filter 'DepositionRendererTests|DepositionMetamorphicTests'
```

Exit status: `0`; 52 tests in two suites passed, including prediction,
estimated-update, replay preflight atomicity, bounded projected-instance
failure, append-only deposition, preview/commit parity, and six canonical
metamorphic cases.

### Actual Technical Ink endpoint

```bash
swift test --filter fastReleaseTechnicalInkKeepsVisibleEndpointAtPointerUp
```

Exit status: `0`; the Metal-rendered 40 px stabilized fast-release trace now
keeps visible support at the pointer-up endpoint.

### Task 2 expected-red delta

```bash
swift test --filter 'BrushCorrectiveFunctionalTests|ProfessionalStrokeTraceTests'
```

Exit status: `1` as expected. Twelve tests ran. Both Technical Ink defect tests
now pass. Five intentional issues remain unchanged in meaning:

- Graphite support p50 `10 < 20` and p95 `10 < 24`;
- Charcoal changed pixels `0 < 512` and alpha p50 `0 < 0.10`;
- Chisel right-angle protrusion approximately `14.92 > 4`.

The fixture thresholds and diagnostic baseline policy were not changed.

### Repository checks

`git diff --check` exits `0`, and no production/test reference to
`applyingKnownTotalDistance` remains.

## Sequencing notes and risks

- Per parent sequencing direction, this task establishes the internal causal
  model while `BrushDefinition.currentSchemaVersion` remains 1. Task 9 owns the
  serialized schema-v2 bump, BrushFormat migration, canonical content hashing,
  and package compatibility changes. Until Task 9, changing only a native
  termination policy is not yet represented in `BrushContentHash`; no current
  accepted product brush depends on such a persisted distinction.
- `pressureRelease` and `boundedCorrection` are compiled and independently
  policy-validated here. Current rebuilt dry presets use `.cap`; later runtime
  coordination tasks can consume the other decisions without changing their
  causal/limit contract.
- Retained replay infrastructure intentionally remains for named schema-v1
  compatibility, prediction/estimated-update behavior, and bounded wet work.
  Stage B Tasks 5–7 replace and isolate those runtime responsibilities.
- `.vscode/` and `brushes/procreate/1_FREE_Charcoal_Set.key` remain untracked
  and untouched.
