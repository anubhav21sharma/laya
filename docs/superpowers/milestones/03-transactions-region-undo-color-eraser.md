# Slice 3: Transactions, Region Undo, Color, And Eraser

- **Status:** Pending Performance And Manual Acceptance
- **Date:** 2026-07-21
- **Implementation evidence commit:**
  `248004d8f1b1715aaa860bf6b24d0a954fc8c1e1`
- **Final evidence-hardening commit:**
  `248004d8f1b1715aaa860bf6b24d0a954fc8c1e1`
- **Branch:** `main`
- **Authorized base:** `0587d2cecfae51cd6050193a00dd4cd87511abf3`

## Scope Delivered

Slice 3 now has a strict schema-4 real-Metal acceptance harness and one-shot
gate for the editor behavior implemented by Tasks 1–9. Schema 1–3 decoding and
validation remain strict. The schema-4 runner lives in the app layer and drives
the production `DocumentHistory` orchestration seam: successful raster,
resize, and tiling edits append real commands; undo/redo use two-phase
`beginUndo`/`beginRedo` and `finishNavigation`; discarded redo revision IDs
are forwarded to the renderer release sink.

The six families prove colored drawing, live/committed erasing, separated
seam-region undo/redo, clear undo/redo, metadata-only tiling undo, and
top-left crop/transparent-fill resize undo/redo. Schema-4 benchmark records
require revision capture/restore times, retained history bytes and commands,
undo/redo availability, append and navigation-finalization counts, released
revision count, family-specific mismatch counts, and changed-region count.
Every required numeric value is finite and nonnegative.

The gate also corrects the stale Slice 2 projected-instance ABI assertion from
96 to 112 bytes. The four-fragment generalized-grid case is checked as exactly
448 bytes.

Final evidence hardening adds family-specific negative controls for colored
output and eraser preview/commit equivalence. It keeps a six-scene exact truth
table, strict record keys, 112-byte instance accounting, exact PNG
names/counts/dimensions, real PNG decoding, and common
hardware/OS/configuration/commit provenance. The gate rejects untracked build
inputs, permits unrelated `.vscode/` files, repeats provenance validation after
artifact generation, and pins the macOS destination to the deterministic host
architecture (`arm64` on this host).

The corrected completion path retains validator status 2 as deferred
performance-pending state. It then runs both generated-artifact ignore and
final source-provenance audits. An audit failure overrides the deferred
pending result; only successful audits permit the exact pending diagnostic.
Hard validation failures remain immediate, while stable validation success
continues to performance budgets and the pass path.

## Environment And Provenance

- GPU: `Apple Paravirtual device`
- Operating system: `Version 26.5.2 (Build 25F84)`
- Logical processors: `8`
- Physical memory: `8589934592` bytes
- Build configuration: `Debug`
- Harness timestamp: `2026-07-21T01:44:50Z` through
  `2026-07-21T01:44:51Z`
- Every retained Slice 3 benchmark record identifies implementation commit
  `248004d8f1b1715aaa860bf6b24d0a954fc8c1e1` and its exact schema-4
  program identity.

This device is a paravirtual GPU, so its real command-buffer timings are not a
stable real-Metal performance acceptance environment. The measurements below
are retained as exact diagnostics, not promoted or aggregated into a pass.

## Automated Evidence

The single authorized corrected invocation of `./scripts/verify-slice3.sh`
completed every functional stage in fixed order against committed HEAD
`248004d8f1b1715aaa860bf6b24d0a954fc8c1e1`:

- Slice 0 automated gate: passed.
- Slice 1 functional gate, including the Slice 0 regression: passed under its
  explicit functional-only performance override.
- Swift tests: `321 tests in 5 suites` passed, including real
  `DocumentHistory` append/navigation evidence tests, strict schema-4
  corruption tests, gate provenance fixtures, executable deferred-pending
  completion-audit tests, and deterministic destination assertions.
- Xcode project generation: succeeded.
- macOS Debug build for `platform=macOS,arch=arm64`: `BUILD SUCCEEDED`, with
  no ambiguous-destination warning.
- Generic iPadOS Simulator Debug build: `BUILD SUCCEEDED`.
- Slice 2 correctness replay: `26 / 26` scenes passed and wrote benchmark
  records. This does not claim Slice 2 performance or manual acceptance.
- Slice 3 exact negative controls: `6 / 6` failed for the named structural
  assertion, before their corresponding positives.
- Slice 3 positives: `6 / 6` passed, wrote `33` PNG artifacts and `6`
  schema-4 benchmark records.
- Artifact-family, exact-key schema-4 benchmark, real history-state,
  finite/nonnegative, 112-byte instance-ABI, generalized-grid 448-byte,
  committed-source provenance, and ignore checks: passed before the deferred
  performance result was emitted. The generated-artifact ignore audit and
  final source-provenance recheck both ran after the long build/harness
  interval and passed.

The deferred performance result then stopped the one-shot gate with exactly:

```text
SLICE3 PERFORMANCE PENDING: unstable real-Metal timing environment 'Apple Paravirtual device'.
SLICE3 GATE ERROR: stable real-Metal performance acceptance remains pending
```

Gate stdout is empty. No `SLICE3 GATE PASS` line was printed or claimed.

## Negative-First Proofs

Each negative scene differs from its positive only by its named expected
structural value changing from `0` to `1`. Exit status was exactly 1 and stderr
was exactly one of these lines:

```text
HARNESS FAIL Slice 3 scene 'colored-draw-negative-control' metric coloredOutputMismatchCount: expected equal 1, actual 0.
HARNESS FAIL Slice 3 scene 'eraser-live-commit-negative-control' metric previewCommitViolationCount: expected equal 1, actual 0.
HARNESS FAIL Slice 3 scene 'region-undo-seam-negative-control' metric undoCanonicalByteDelta: expected equal 1, actual 0.
HARNESS FAIL Slice 3 scene 'clear-undo-negative-control' metric redoCanonicalByteDelta: expected equal 1, actual 0.
HARNESS FAIL Slice 3 scene 'tiling-undo-negative-control' metric metadataCanonicalByteDelta: expected equal 1, actual 0.
HARNESS FAIL Slice 3 scene 'resize-crop-fill-negative-control' metric redoCanonicalByteDelta: expected equal 1, actual 0.
```

The colored positive independently checks the committed canonical BGRA value
and records zero `coloredOutputMismatchCount`. The eraser positive checks the
transparent destination-out canonical pixel and records zero
`previewCommitViolationCount` across all live/committed channels at tolerance
1. The region positive enforces two separated changed regions; the tiling
positive enforces zero canonical delta; and all byte-exact undo/redo and
resize-dimension assertions passed.

## Exact Benchmark Diagnostics

The arrays below are the stored measurements in record order. They are not
percentiles, averages, filtered samples, warmups, retries, or synthetic
aggregates. Empty arrays mean that operation is not part of that scene.

### `colored-draw`

- brush processing ms: `[0.2269744873046875, 0.10693073272705078]`
- dab GPU ms: `[1.1535000085132197]`
- grid GPU ms: `[0.5553750088438392, 0.5519166734302416]`
- commit GPU ms: `[0.612833333434537]`
- event-to-submit ms: `[0.2789497375488281]`
- revision capture ms: `[0.8120536804199219]`
- revision restore ms: `[0.5609989166259766, 0.27501583099365234]`
- history bytes/commands/appends/navigation finishes/releases:
  `4224 / 1 / 1 / 2 / 0`; `canUndo=true`, `canRedo=false`
- family-specific mismatch count / changed regions: `0 / 1`
- frames/missed/peak resident: `4 / 0 / 22888448` bytes
- projected fragments / maximum / instance bytes: `1 / 1 / 112`

### `eraser-live-commit`

- brush processing ms: `[0.24008750915527344, 0.7290840148925781, 0.05996227264404297, 0.033974647521972656]`
- dab GPU ms: `[1.3910000125179067, 0.6252916646189988]`
- grid GPU ms: `[0.5618333234451711, 0.5247916706139222, 0.5874999915249646]`
- commit GPU ms: `[1.2416250101523474, 0.5402083334047347]`
- event-to-submit ms: `[0.904083251953125, 0.07700920104980469]`
- revision capture ms: `[1.495957374572754, 0.6350278854370117]`
- revision restore ms: `[0.5040168762207031, 0.2919435501098633]`
- history bytes/commands/appends/navigation finishes/releases:
  `8448 / 2 / 2 / 2 / 0`; `canUndo=true`, `canRedo=false`
- family-specific mismatch count / changed regions: `0 / 1`
- frames/missed/peak resident: `7 / 0 / 23019520` bytes
- projected fragments / maximum / instance bytes: `1 / 1 / 112`

### `region-undo-seam`

- brush processing ms: `[0.20802021026611328, 0.06401538848876953]`
- dab GPU ms: `[1.1295000003883615]`
- grid GPU ms: `[0.977624993538484, 0.31037500593811274]`
- commit GPU ms: `[0.6635416648350656]`
- event-to-submit ms: `[0.24402141571044922]`
- revision capture ms: `[0.9249448776245117]`
- revision restore ms: `[0.5509853363037109, 0.2759695053100586]`
- history bytes/commands/appends/navigation finishes/releases:
  `1792 / 1 / 1 / 2 / 0`; `canUndo=true`, `canRedo=false`
- family-specific mismatch count / changed regions: `0 / 2`
- frames/missed/peak resident: `4 / 0 / 22822912` bytes
- projected fragments / maximum / instance bytes: `2 / 2 / 224`

### `clear-undo`

- brush processing ms: `[0.2338886260986328, 0.08690357208251953]`
- dab GPU ms: `[1.1364166712155566]`
- grid GPU ms: `[0.5636249989038333, 0.5201666645007208]`
- commit GPU ms: `[1.0583333350950852]`
- event-to-submit ms: `[0.25784969329833984]`
- revision capture ms: `[1.2969970703125, 0.635981559753418]`
- revision restore ms: `[0.25904178619384766, 0.2720355987548828]`
- history bytes/commands/appends/navigation finishes/releases:
  `135296 / 2 / 2 / 2 / 0`; `canUndo=true`, `canRedo=false`
- family-specific mismatch count / changed regions: `0 / 1`
- frames/missed/peak resident: `4 / 0 / 23035904` bytes
- projected fragments / maximum / instance bytes: `1 / 1 / 112`

### `tiling-undo`

- brush processing ms: `[0.21195411682128906, 0.06794929504394531]`
- dab GPU ms: `[1.153000004705973]`
- grid GPU ms: `[0.7460416672984138, 0.6455416732933372, 0.6240000075194985, 0.33024999720510095, 0.31658333318773657]`
- commit GPU ms: `[0.636875003692694]`
- event-to-submit ms: `[0.19991397857666016]`
- revision capture ms: `[0.8549690246582031]`
- revision restore ms: `[]`
- history bytes/commands/appends/navigation finishes/releases:
  `4416 / 2 / 2 / 2 / 0`; `canUndo=true`, `canRedo=false`
- family-specific mismatch count / changed regions: `0 / 0`
- frames/missed/peak resident: `7 / 0 / 23396352` bytes
- projected fragments / maximum / instance bytes: `1 / 1 / 112`

### `resize-crop-fill`

- brush processing, dab GPU, commit GPU, and event-to-submit ms: `[]`
- grid GPU ms: `[1.0368333314545453]`
- revision capture ms: `[1.3309717178344727, 2.1200180053710938]`
- revision restore ms: `[0.8449554443359375, 0.7709264755249023, 0.7159709930419922, 0.7519721984863281]`
- history bytes/commands/appends/navigation finishes/releases:
  `104448 / 2 / 2 / 4 / 0`; `canUndo=true`, `canRedo=false`
- family-specific mismatch count / changed regions: `0 / 2`
- frames/missed/peak resident: `1 / 0 / 22937600` bytes
- projected fragments / maximum / instance bytes: `0 / 0 / 0`

## Retained Evidence

- Corrected one-shot stdout: `.build/final-rereview-gate.stdout.log` (empty)
- Corrected one-shot stderr: `.build/final-rereview-gate.stderr.log`
- Corrected one-shot exit status: `.build/final-rereview-gate.exit` (`1`)
- Stage logs: `.build/slice3-slice0-functional.log`,
  `.build/slice3-slice1-functional.log`, `.build/slice3-swift-test.log`,
  `.build/slice3-xcodegen.log`, `.build/slice3-macos-build.log`,
  `.build/slice3-ipados-build.log`, and
  `.build/slice3-evidence-validator-build.log` plus
  `.build/slice3-strict-evidence.log`
- RED evidence: `.build/final-evidence-red.log` and
  `.build/final-evidence-runner-red.log`; corrected completion-audit RED is
  `.build/final-rereview-red.log`
- Focused GREEN evidence: `.build/final-evidence-history-green.log` and
  `.build/final-evidence-focused-green.log`; corrected gate control-flow
  GREEN is `.build/final-rereview-green.log`, with all five gate-focused
  tests in `.build/final-rereview-gate-focused.log`
- Corrected full precommit test evidence:
  `.build/final-rereview-swift-test-precommit.log`
- Slice 2 correctness artifacts: `.build/slice3-artifacts/slice2/`
- Exact negative stderr and negative artifacts:
  `.build/slice3-artifacts/negative-control/`
- Positive PNGs, stdout, and benchmark records:
  `.build/slice3-artifacts/positive/`

All retained evidence is ignored build output and is not an accepted portable
baseline.

## Manual Mac Gate

The current host is locked/noninteractive. `./scripts/run-macos.sh` was not
used to claim visual interaction evidence, and every manual result remains
pending:

- [ ] Draw and Erase controls remain in stable positions.
- [ ] Tool and color focus changes do not steal later editor shortcuts.
- [ ] `B`, `E`, `0`, `+`, `=`, `-`, `<`, `>`, `G`, `1...7`, `Command-Z`,
      and `Command-Shift-Z` work after drawing and after clicking controls.
- [ ] Toolbar, keyboard, and menu paths keep brush diameter and grid
      visibility synchronized.
- [ ] Color picker changes draw RGB and opacity.
- [ ] Eraser removes artwork live with no pointer-up change.
- [ ] Undo/redo works for draw, erase, clear, tiling, and resize.
- [ ] Tiling undo changes display without changing canonical pixels.
- [ ] Shrink crops only the right/bottom; growth adds transparent
      right/bottom space.
- [ ] Resize undo/redo restores exact dimensions and visible pixels.
- [ ] Busy controls disable during submitted GPU work.
- [ ] Grid controls and menu commands stay synchronized and visibly correct.
- [ ] Pan, cursor-anchored zoom, resize, stroke direction, and pointer/cursor
      alignment remain correct.

## Acceptance Status And Deviations

The functional implementation and automated correctness gates are complete.
Slice 3 is not accepted because stable real-Metal performance and the manual
Mac checklist remain pending. Slice 2 also remains `Pending Performance And
Manual Acceptance`; its 26-scene replay is functional regression evidence
only.

Approved deviations/overrides are exact and limited to:

1. The user authorized Slice 3 work while Slice 2 performance and manual
   acceptance remain pending; no Slice 2 threshold or status was changed.
2. The user authorized correcting the stale Slice 2 96-byte assertion to the
   current 112-byte projected-instance ABI, including exact 448-byte checking
   for four fragments.
3. On a paravirtual/locked host, performance and manual sweeps remain honestly
   pending. There was no retry, warmup filtering, timing skip, sample
   filtering, synthetic aggregation, threshold relaxation, pass output, or
   push.

No other deviation from the approved Slice 3 design is recorded.
