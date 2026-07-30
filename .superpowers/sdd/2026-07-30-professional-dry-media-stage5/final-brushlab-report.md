# Final Brush Lab Report — Executable Professional Cards

## Outcome

The Stage 5 professional review matrix is now selectable and executable in the
production Brush Lab. Its 68 cards use the four production professional brush
definitions, preserve ordered multi-pass actions, and drive the real
`EditorSessionController`/Metal renderer path. Stage 4 diagnostic cards remain
available through a separate review mode and retain their frozen schema-v1
bytes.

The shipped UI now exposes:

- a Stage 4 / Stage 5 review-matrix picker;
- the complete professional-card list;
- replay-all and ordered replay-next-pass actions;
- visible current/next pass state and per-pass brush, tool, input, diameter,
  and stroke counts;
- separate Stage 4 evidence and Stage 5 professional-matrix exports.

## RED evidence

Before production changes, this focused command failed:

```text
swift test --disable-sandbox --no-parallel --filter 'BrushLabSessionTests.professional(CardCanBeSelectedThroughProductionReviewPath|PressureTiltAndDeviceScenariosDriveNamedInputs|MultiStrokeAndEraserLabelsDescribeExecutableActions)'
```

It recorded 14 issues:

- professional cards could not be selected through the production review path;
- pressure-ramp, tilt, and tablet cards were reported as mouse input;
- pressure and altitude remained constant instead of exercising their named
  dynamics;
- crosshatch and buildup each executed as only one stroke;
- the eraser scenario had no eraser role or erase action.

The first complete serial run later exposed seven legitimate pre-existing
fixture failures in the native deposition failure/layer matrices. Multi-layer
fixture definitions used two shapes or two grains without declaring the
required `dualShape` / `dualGrain` capabilities. The validator was not weakened;
the fixture definition factory now derives the sorted required declarations
from its actual layer counts.

## Implementation and contracts

- Added a separate Stage 5 professional card model with catalog schema 3 and
  card schema 2. Cards contain ordered passes, strokes, and exact input samples.
- Kept the Stage 4 `BrushLabManualCard` schema and assessment model unchanged.
  Its frozen catalog hash remains
  `6490bcf5d3d452e523b0eba7293b1bf8050ae8445a41941592bbb60c91bf7a32`.
- The Stage 5 matrix canonical-card hash is
  `ef36da0a12c26ea335032b4f596005b762617da6f7057fe47ffc1031872fdf5e`.
- Added exact mouse, Pencil pressure, Pencil tilt, and tablet input contracts.
  Mouse samples contain no Pencil-only angles.
- Added four-stroke crosshatch, four-pass-over buildup, distinct curve/corner
  traces, slow/fast timing, minimum/nominal/maximum tap diameters, periodic
  seam coverage, and radial rotation/mirror coverage.
- The eraser card is an ordered two-pass replay: professional draw followed by
  the retained built-in eraser over the matching path.
- Professional selection compiles and installs both draw and eraser brushes.
  A compilation failure leaves the previously active renderer and selected card
  intact.
- Added pass-level replay records binding role, tool, brush identity, semantic
  hash, input source, diameter, stroke count, input range, and dab range.
- Replaced permissive professional manual validation with exact-key,
  exact-order, fail-closed validation at every catalog/card/pass/stroke/sample
  and assessment level. Boolean-as-number and partial assessment completion are
  rejected.

No production source membership changed, so project regeneration/bootstrap and
scheme analyses were not required.

## Final verification

All commands below were run against the final source state.

```text
swift test --disable-sandbox --no-parallel --filter BrushLabSessionTests
```

Passed: 32 tests in 1 suite.

```text
swift test --disable-sandbox --no-parallel --filter DepositionHarnessRunnerTests
```

Passed: 10 tests in 1 suite, including all 16 positive scenes, all 16 paired
negative controls, the complete 18-way layer matrix, and the failure-matrix
atomicity invariants.

```text
swift test --disable-sandbox --no-parallel --filter 'ProfessionalBrush(HarnessRunner|EvidenceValidator)Tests|professionalManual'
```

Passed: 24 tests in 3 suites, including all four positive and four paired
negative professional Metal scenes and complete artifact-root validation.

```text
swift test --disable-sandbox --no-parallel
```

Passed: 1,264 tests in 70 suites in 303.735 seconds.

```text
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -configuration Debug -destination 'platform=macOS' build
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

Both builds succeeded.

```text
git diff --check
```

Passed with no whitespace errors.

## Remaining user-owned evidence

Manual perceptual assessments remain unset and user-owned. Real Apple Pencil,
Wacom/tablet, and physical-device performance evidence remains pending. The
synthetic executable cards validate routing and semantics but do not claim
human visual approval or physical-device evidence.

## Review-state preservation follow-up

The post-implementation review findings are closed without changing either
manual-card catalog:

- Professional draw and retained-eraser packages now compile into an isolated
  compiler batch. Cache, counters, active brush, diagnostics, renderer state,
  document state, replay state, and Brush Lab observables publish only after
  both compiles succeed.
- Selection resets through one awaited production-controller operation, then
  installs the draw/eraser pair and publishes the selected card together.
  Plain, periodic, and radial-rotation cards can now be selected and replayed
  sequentially with empty history at each boundary.
- Concurrent selection is generation-guarded; a superseded compilation cannot
  replace the latest selected card or compiler state.
- Professional replay reuses the committed brush pair instead of recompiling
  and mutating inspection state.
- Every named professional scenario now has an explicit semantic validator for
  its literal pass/stroke/sample counts, lifecycle phases, actual/predicted
  kinds, timing, geometry, source, capabilities, pressures, angles, document
  geometry, and retained-eraser contract. These errors are reported before the
  canonical digest boundary.
- Stage 4 bytes remain frozen, and the Stage 5 canonical-card hash remains
  `ef36da0a12c26ea335032b4f596005b762617da6f7057fe47ffc1031872fdf5e`.

The RED transition test originally failed with
`documentConfigurationUnavailable` on a non-empty document. The complete
state-snapshot test proved that the old failure path cleared replay/session
state, and the per-scenario mutation matrix recorded 15 missing or non-specific
semantic failures before the explicit validator was added.

Final focused verification:

```text
swift test --disable-sandbox --no-parallel --filter BrushLabSessionTests
```

Passed: 35 tests in 1 suite, including sequential configuration transitions,
latest-selection race handling, full observable-state preservation on the
second compilation failure, all existing replay/export contracts, and all 15
scenario-specific semantic mutations.

```text
swift build --disable-sandbox --target ProfessionalBrushEvidenceValidation
git diff --check
```

Both passed.
