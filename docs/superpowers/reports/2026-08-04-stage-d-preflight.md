# Stage D preflight — frozen contracts

Baseline commit: `af5953a` (Stage C accepted boundary). This preflight adds
test-only evidence; it does not modify Stage D production behavior.

## Paint-surface inventory

| Owner | Source | Current paint-bearing BGRA8 textures |
| --- | --- | ---: |
| `CanonicalRaster` | `Sources/MetalRenderer/CanonicalRaster.swift` | 2 |
| `PersistentLiveTile` | `Sources/MetalRenderer/PersistentLiveTile.swift` | 1 |
| `ReplayLiveTile` | `Sources/MetalRenderer/Brush/ReplayLiveTile.swift` | 1 |
| `StrokeMetalSurfaceResources` | `Sources/MetalRenderer/StrokeRuntime/StrokePrivateSurfaceEncoder.swift` | 2 |

`StageDBaselineContractTests` has the executable version of this inventory.
Task 5 must invert it when these six full-canvas paint textures are replaced.

## Independent color counterexamples

The test fixtures retain encoded BGRA8 bytes and hand-derived IEC 61966-2-1
linear references for empty, translucent, low-flow buildup, erase, periodic
seam, and radial-page samples. These are import/reference vectors only: no
current renderer blend output is asserted as color truth. Alpha remains linear.

Dry semantic/canonical fixture hashes are frozen for empty, periodic seam, and
radial-page cases in the same test file.

## Project compatibility archives

| Archive | Input SHA-256 | Deterministic v3 re-encode SHA-256 |
| --- | --- | --- |
| v1 single transparent raster | `0d670938b2b95253f8dc3147833b2497b07ba5838d218a08de51f292915ba894` | `1c04150a60fc56e34cea2ca3fc0ebc1ebc463e06125d0e0300e88580de74c97a` |
| v2 layer metadata | `c1904ed355876513cd9a461a13dd3e70c15929dcc6b95437c28552240ad4c0cf` | `cbde346d978c422c19c183aef2467d72393393414f2359b7f0fac92a81730950` |
| v3 radial pages | `21b573da781e279c85559fd6d348a3faa38fdc48b8b98e62f549d1f06817e7ec` | `21b573da781e279c85559fd6d348a3faa38fdc48b8b98e62f549d1f06817e7ec` |

The archive fixtures collectively cover single-raster and radial-page storage,
metadata including order, opacity, blend mode, visibility, and lock state, and
transparent pixels.

## Lifecycle owner

One table-driven Stage D test lists all twelve transitions: initialize/import,
begin, append actual/coalesced, replace prediction, prepare/submit/display,
finish/commit, cancel/failure, clear, undo/redo, layer mutation,
resize/mode-switch/import, and export/save. Later tasks add assertions to these
named rows rather than creating another lifecycle owner.

## Verification

- RED: `swift test --filter 'StageDBaselineContractTests|StageDProjectBaselineTests'` failed on the deliberately absent allocation inventory and baseline hashes before the literal contracts were filled.
- GREEN: the same focused command passed 5 tests in 2 suites after the fixtures and hashes were frozen.
- Final focused gate: `swift test --filter 'StageDBaselineContractTests|StageDProjectBaselineTests|StageCAcceptance'`.

The full suite was intentionally not run for this test-only preflight; its
known Stage B baseline remains the 27 issue records in
`Tests/Baselines/stage-b-known-issues.txt`.
