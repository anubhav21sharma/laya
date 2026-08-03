# Task 6 Report — Atomic Definition V2 And Semantic Identity

## Status

DONE

## What I implemented

- Added the Stage C schema-v2 value model for sensor normalization, fourteen
  dynamic outputs with zero through four ordered response terms, stabilization,
  direction/corner behavior, emission, and portable tip support.
- Kept `BrushDefinition.legacySchemaVersion == 1` and made the existing public
  initializer continue to create schema v1. Added a separate fully explicit v2
  initializer requiring every Stage C field without defaults.
- Added version-envelope-first decoding and version-specific v1/v2 DTOs.
  Unknown definition versions fail with the typed
  `unsupportedSchemaVersion(UInt16)` error before a definition is published.
- Added complete schema-specific validation for finite/range constraints,
  ordered response terms and operation domains, output coverage, cyclic
  response rejection, stabilization, direction/corners, emission, and tip
  layer/support cardinality.
- Extended `BrushProgram` and `BrushProgramCompiler` to retain validated Stage C
  metadata only. This task deliberately does not evaluate it; C7 and later tasks
  own runtime behavior.
- Preserved schema-v1 legacy-marker behavior in `LegacyBrushRecipeAdapter` and
  the old termination/random/dab contracts.
- Kept the package manifest at v2 while accepting definition schemas v1 and v2.
  Package validation, decode, hashing, and activation remain transactional.
- Split semantic identity by definition schema only: definition v1 uses hash
  schema 2 and its exact existing canonical byte stream; definition v2 uses hash
  schema 3 and includes every new behavior-bearing Stage C field. Manifest
  version and caller preference do not select the writer.
- Kept all professional presets, anchor presets, and synthetic v1 converter
  outputs on definition schema v1. No preset migration was performed.

## TDD evidence

### RED 1 — frozen schema-v1 contract

The first test cluster pinned the frozen v1 package bytes, decoded fields,
compiled program, semantic digest, and no-read-rewrite behavior. Its first build
failed because the production type did not yet expose the required explicit
legacy schema constant:

```text
error: type 'BrushDefinition' has no member 'legacySchemaVersion'
```

The representative frozen-v1 logical trace was subsequently added with a
deliberately wrong count/digest and failed before the pinned result was installed.

### RED 2 — schema-v2 API and validation

The hand-authored schema-v2 round-trip and boundary tests were added before the
new model. They failed to compile because the v2 sensor/output, stabilization,
direction, emission, tip-support fields, and explicit initializer did not exist.

### RED 3 — semantic hash schema 3

The schema-v2 semantic-identity test was first run with an intentionally invalid
digest placeholder. It failed after the v2 writer produced its deterministic
stream. The exact digest was then pinned, along with mutation coverage for every
Stage C semantic group, ordered-term reordering, dictionary insertion order,
metadata exclusion, and manifest/writer independence.

### RED 4 — frozen-v1 trace

The frozen-v1 trace test first used an intentionally wrong dab count and digest.
It failed, then pinned the observed existing behavior at 21 dabs and the trace
digest listed below. No schema-v1 production behavior was changed to satisfy it.

## Pinned compatibility evidence

- Frozen schema-v1 archive SHA-256:
  `12ab63f9c5588ccd7b625ebb41633221d7bc494e7f5fd21dd90f840efffbf98e`
- Frozen schema-v1 semantic hash-schema-2 digest:
  `5b9ff4f916d0a20dc1df61ad2b53056fe20b9950ea1e90792b96b5f64e1d0912`
- Existing common v1 package digest remains:
  `ed1f9b8e914d9dc597b45ba9b03baccf57194eb2179776f743bdd2d9d0a872fb`
- Frozen schema-v1 representative trace: 21 logical dabs, SHA-256
  `40c4f8b7acfe363ac984f7a40df9bb7792ce24d497f26d69ec97944fcb1b2f86`
- Hand-authored schema-v2/hash-schema-3 fixture digest:
  `bd7bcd38c40ce5c200353d91ef8ff3f0bb958153217240ed192cfbab1bc7e076`

No generated fixture file was checked in. The v2 fixture is the explicit
`BrushFormatTestSupport.v2Definition` source definition compiled by the normal
`swift test` command, so there is no separate fixture-generation command.

## Final verification

Fresh sequential runs after the final source state:

```text
swift test --filter \
  'BrushDefinitionTests|BrushProgramCompilerTests|BrushPackageCodecTests|BrushPackageIOTests|BrushContentHashTests'
Test run with 81 tests in 1 suite passed after 0.096 seconds.
```

```text
swift test --filter \
  'SyntheticV1BrushMapperTests|professionalCatalog|anchorCatalog'
Test run with 22 tests in 3 suites passed after 0.367 seconds.
```

`git diff --check` passed. The changed files contain no temporary digest/trace
placeholders or debug `print` calls.

During development, running multiple `swift test` processes concurrently
against the same `.build` directory produced a testing-helper signal 11 while
the shared test bundle was being rebuilt. It did not reproduce in the required
sequential commands above. The tests are therefore intentionally documented and
verified sequentially; no product crash was hidden or waived.

## Contract coverage

- v1 initializer/schema, decode, marker distinction, hash, bytes, compiler, dab
  trace, catalog, anchor, and converter compatibility: covered;
- explicit v2 initializer and version-specific DTO round-trip: covered;
- typed unsupported-version failure before publication: covered;
- every Stage C validation family and closed finite boundary: covered;
- schema-3 field sensitivity, ordered-term sensitivity, dictionary-order
  independence, and metadata/manifest independence: covered;
- package save/load and frozen-v1 no-read-rewrite behavior: covered;
- compiler storage without runtime evaluation: covered.

## Scope and remaining risk

- C7 owns Stage C sensor/output evaluation. C8-C10 own velocity,
  stabilization/direction, emission, and support integration. This commit only
  establishes and compiles the versioned metadata contract.
- Stage F owns migration of production catalogs and converted brushes to v2.
  All current production brush definitions remain v1 by design.
- No broad suite or million-sample hot-path probe was run because the task brief
  assigns the broad gate to C13 and this task adds no input-path evaluation.
