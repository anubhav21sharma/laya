# Task 0 report — Freeze Stage D Contracts And Counterexamples

## Result

Added test-only Stage D preflight contracts. Production source was not changed.

- `StageDBaselineContractTests` inventories the four paint-surface source sites
  and six full-canvas BGRA8 textures to be inverted at Task 5.
- It contains independent IEC 61966-2-1 encoded-BGRA8-to-linear vectors for
  empty, translucent, low-flow, erase, periodic-seam, and radial-page inputs;
  existing renderer blend output is not asserted as color truth.
- It freezes dry fixture semantic/canonical SHA-256 values and one table-driven
  owner for all twelve Stage D lifecycle transitions.
- `StageDProjectBaselineTests` freezes v1/v2/v3 archive SHA-256 values,
  decoded rasters, and deterministic current-schema re-encoding. The fixtures
  cover a transparent single raster, multi-layer metadata, and radial pages.

## TDD evidence

RED was observed with the new assertions before baseline literals were filled:
the paint-allocation inventory did not match and the archive/dry-scene baseline
hashes were intentionally absent. The subsequent GREEN run passed.

## Verification

`swift test --filter 'StageDBaselineContractTests|StageDProjectBaselineTests|StageCAcceptance'`

Result: 12 tests in 3 suites passed.

The broad suite was not run for this test-only preflight. The known broad-suite
baseline remains exactly the 27 Stage B issue records in
`Tests/Baselines/stage-b-known-issues.txt`; no record was changed or normalized.

## Scope and review

Self-review: no production files changed; only the two requested test files,
preflight report, and corrective-program ledger were added/updated. Unrelated
`.vscode/` and `brushes/procreate/1_FREE_Charcoal_Set.key` remain untracked and
will not be staged.
