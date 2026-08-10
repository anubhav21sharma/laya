# Native Current-Only Formats And Boundary Validation Design

**Status:** Approved direction from the project owner on 2026-08-10.

## Goal

Keep Laya's pre-release architecture free of backward-compatibility debt and
concentrate validation at boundaries where untrusted data, bounded resources,
transactional publication, or asynchronous ownership can actually fail.

## Scope

This design applies to every remaining corrective stage and to all Laya-native
project, brush, package, renderer, harness, evidence, and other pre-release
formats. It supersedes earlier requirements to migrate or preserve native
schema versions, identifiers, aliases, execution paths, or raster output.

External formats are different. Procreate brushes and other explicitly
supported foreign inputs remain product features. Their parsers stay defensive
and convert accepted input directly into the one current Laya-native model.

## Decisions

### One current native format

- The current project format remains numerically schema 4, but only schema 4
  is accepted. Versions 1, 2, 3, unknown future versions, and incomplete
  pre-release archives fail immediately with a typed unsupported-version error.
- The current brush-definition schema 2 and package-manifest schema 2 remain
  numerically unchanged until the planned composite-brush cutover. Only the
  exact current version of each is accepted. At corrective Task 18—after Tasks
  15 through 17 establish resource, cursor, and backend foundations—every
  in-tree definition producer moves to definition schema 3 in the same slice;
  definition schemas 1 and 2 are rejected rather than migrated. The package
  manifest stays current-only schema 2 unless its own wire layout changes, and
  its package payload then requires a schema-3 definition.
- Numeric versions are not reset merely for aesthetics. Current-only equality
  checks remove compatibility complexity; renumbering stable current wire
  layouts would add work without improving architecture.
- Retired catalog IDs, source aliases, magic compatibility layer IDs,
  deprecated initializers, schema adapters, and old execution selectors are
  deleted. Unsupported native identifiers fail clearly.

### Boundary validation topology

Validation remains strong at these boundaries:

1. Untrusted project/package bytes and external brush input: container paths,
   sizes, counts, schemas, hashes, finite values, semantic capability, and
   aggregate budgets are validated before constructing trusted native values.
2. Checked arithmetic and resource planning: dimensions, byte products,
   residency, Metal texture/buffer limits, binding capacity, and allocation
   budgets are validated before resource ownership begins.
3. Transactional publication: candidates are complete and generation-current
   before one atomic registry/history/document swap.
4. GPU and asynchronous ownership: leases, submissions, completion, cancellation,
   retryable retirement, and shutdown settle exactly once without leaks.

After a boundary succeeds, internal code consumes trusted, immutable types or
unforgeable capabilities. It does not repeat schema, geometry, range, identity,
or ownership checks already guaranteed by construction.

### Validation and test consolidation

- Prefer private initializers, current-only decoded types, typed prepared
  transactions, and ownership state machines over repeated runtime guards.
- Delete source-text scanners after the code they temporarily police is
  physically removed or made unrepresentable by module/access boundaries.
- Delete duplicate invariant tests that restate the same guarantee at every
  internal layer. Keep the boundary test, the meaningful consumer behavior,
  and the end-to-end vertical-slice proof.
- Keep fault injection only for realistic corruption, allocation, publication,
  GPU, cancellation, and ownership failures. Remove hooks that exist solely to
  manufacture impossible internal states.
- Use focused tests during red/green implementation, functional and performance
  tests at meaningful vertical-slice boundaries, and the full adversarial
  matrix at stage acceptance.
- Review meaningful task/slice boundaries. Minor edits within an open slice are
  covered by its focused gate and scoped final review instead of triggering a
  new full review cycle.

## Dependency-Ordered Removal

### Stage D Task 6 cutover

- Delete full-canvas canonical/live/replay owners, legacy scheduler/resource
  selectors, synchronous compatibility rendering, old harness schemas, and
  magic compatibility-layer routing when the shared sparse document context
  becomes the sole GridRenderer authority.
- Keep one temporary cutover inventory only until deletion is proven. Replace
  it afterward with behavioral allocation, render, cancellation, and ownership
  evidence.
- Remove duplicate source-shape gates and compatibility constructors once the
  sole construction path is enforced by access control and trusted types.

### Stage D Task 7 persistence

- Delete project schema-v1/v2/v3 decode, migration metadata, legacy symmetry
  wires, native PNG migration, and compatibility-layer IDs.
- Decode only schema 4 into one validated current-project representation.
  Streaming tile upload/save consumes that trusted representation without
  revalidating the same metadata at each layer.
- Keep archive path/count/size/hash validation at the SafeArchive/PatternFile
  boundary and atomic publication checks at the document-store boundary.

### Before Stage E

- Migrate every in-tree brush producer, built-in, converter output, harness,
  and test factory to the current definition/package schema.
- Delete `LegacyBrushRecipeAdapter`, native `BrushRecipe` compatibility
  serialization, schema-v1 program/compiler/dynamics/generator/stabilizer
  branches, whole-stroke legacy replay, retired brush aliases, and compatibility
  hashes/fixtures/tests.
- Preserve external Procreate/Synthetic source parsers, import provenance,
  unsupported-semantic diagnostics, and resource capability declarations.
  They emit the current Laya-native model directly.

### Stages E through G

- New native schema revisions are hard cutovers while the product remains
  unreleased: migrate in-tree producers in the same slice, reject prior native
  versions, and do not add adapters.
- Every just-in-time stage preflight inventories remaining compatibility and
  duplicated validation in the files it will touch, then deletes what its new
  trusted boundary supersedes.

## Non-Negotiable Outcomes

Simplification must not weaken functional correctness, visual quality,
performance, cancellation safety, data integrity, transactional behavior, or
leak-free resource ownership. A removed guard is acceptable only when a stronger
construction, boundary, or ownership guarantee makes its invalid state
unrepresentable or detects it before mutation.
