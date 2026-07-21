# Slice 3: Transactions, Region Undo, Color, And Eraser

- **Status:** Pending Performance And Manual Acceptance
- **Date:** 2026-07-21
- **Implementation evidence commit:**
  `048fdcb6280b826734d541de4b7f2208a50b478a`
- **Final evidence-hardening commit:**
  `048fdcb6280b826734d541de4b7f2208a50b478a`
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

## Environment And Provenance

- GPU: `Apple Paravirtual device`
- Operating system: `Version 26.5.2 (Build 25F84)`
- Logical processors: `8`
- Physical memory: `8589934592` bytes
- Build configuration: `Debug`
- Harness timestamp: `2026-07-21T01:21:14Z` through
  `2026-07-21T01:21:16Z`
- Every retained Slice 3 benchmark record identifies implementation commit
  `048fdcb6280b826734d541de4b7f2208a50b478a` and its exact schema-4
  program identity.

This device is a paravirtual GPU, so its real command-buffer timings are not a
stable real-Metal performance acceptance environment. The measurements below
are retained as exact diagnostics, not promoted or aggregated into a pass.

## Automated Evidence

The single authorized final invocation of `./scripts/verify-slice3.sh`
completed every functional stage in fixed order against committed HEAD
`048fdcb6280b826734d541de4b7f2208a50b478a`:

- Slice 0 automated gate: passed.
- Slice 1 functional gate, including the Slice 0 regression: passed under its
  explicit functional-only performance override.
- Swift tests: `319 tests in 5 suites` passed, including real
  `DocumentHistory` append/navigation evidence tests, strict schema-4
  corruption tests, gate provenance fixtures, and deterministic destination
  assertions.
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
  committed-source provenance, and ignore checks: passed before the
  performance stop. The final source-provenance recheck also passed.

The performance evaluator then stopped the one-shot gate with exactly:

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

- brush processing ms: `[0.20897388458251953, 0.06902217864990234]`
- dab GPU ms: `[1.0458749893587083]`
- grid GPU ms: `[0.5049166647950187, 0.519041670486331]`
- commit GPU ms: `[0.5908750026719645]`
- event-to-submit ms: `[0.2840757369995117]`
- revision capture ms: `[0.8150339126586914]`
- revision restore ms: `[0.5650520324707031, 0.5260705947875977]`
- history bytes/commands/appends/navigation finishes/releases:
  `4224 / 1 / 1 / 2 / 0`; `canUndo=true`, `canRedo=false`
- family-specific mismatch count / changed regions: `0 / 1`
- frames/missed/peak resident: `4 / 0 / 22921216` bytes
- projected fragments / maximum / instance bytes: `1 / 1 / 112`

### `eraser-live-commit`

- brush processing ms: `[0.25594234466552734, 0.08094310760498047, 0.05900859832763672, 0.029921531677246094]`
- dab GPU ms: `[1.3571250019595027, 0.6505416677100584]`
- grid GPU ms: `[0.5622500029858202, 0.5705000075977296, 0.5762083310401067]`
- commit GPU ms: `[0.6302499969024211, 0.5383333336794749]`
- event-to-submit ms: `[0.2799034118652344, 0.06985664367675781]`
- revision capture ms: `[0.8399486541748047, 0.6340742111206055]`
- revision restore ms: `[0.5810260772705078, 0.5210638046264648]`
- history bytes/commands/appends/navigation finishes/releases:
  `8448 / 2 / 2 / 2 / 0`; `canUndo=true`, `canRedo=false`
- family-specific mismatch count / changed regions: `0 / 1`
- frames/missed/peak resident: `7 / 0 / 22970368` bytes
- projected fragments / maximum / instance bytes: `1 / 1 / 112`

### `region-undo-seam`

- brush processing ms: `[0.22399425506591797, 0.06699562072753906]`
- dab GPU ms: `[1.0531250009080395]`
- grid GPU ms: `[1.2492916721384972, 0.5336666654329747]`
- commit GPU ms: `[0.8394583419431001]`
- event-to-submit ms: `[0.19800662994384766]`
- revision capture ms: `[1.1060237884521484]`
- revision restore ms: `[0.3609657287597656, 0.30100345611572266]`
- history bytes/commands/appends/navigation finishes/releases:
  `1792 / 1 / 1 / 2 / 0`; `canUndo=true`, `canRedo=false`
- family-specific mismatch count / changed regions: `0 / 2`
- frames/missed/peak resident: `4 / 0 / 22855680` bytes
- projected fragments / maximum / instance bytes: `2 / 2 / 224`

### `clear-undo`

- brush processing ms: `[0.1989603042602539, 0.0890493392944336]`
- dab GPU ms: `[1.0687500034691766]`
- grid GPU ms: `[0.4816250002477318, 0.5902499979129061]`
- commit GPU ms: `[0.6311250035651028]`
- event-to-submit ms: `[0.23305416107177734]`
- revision capture ms: `[0.8620023727416992, 1.701951026916504]`
- revision restore ms: `[0.532984733581543, 0.5069971084594727]`
- history bytes/commands/appends/navigation finishes/releases:
  `135296 / 2 / 2 / 2 / 0`; `canUndo=true`, `canRedo=false`
- family-specific mismatch count / changed regions: `0 / 1`
- frames/missed/peak resident: `4 / 0 / 22953984` bytes
- projected fragments / maximum / instance bytes: `1 / 1 / 112`

### `tiling-undo`

- brush processing ms: `[0.21207332611083984, 0.07903575897216797]`
- dab GPU ms: `[1.1458333319751546]`
- grid GPU ms: `[0.634291660389863, 0.3760000108741224, 0.37133332807570696, 0.3137500025331974, 0.30716667242813855]`
- commit GPU ms: `[0.720124997314997]`
- event-to-submit ms: `[0.21207332611083984]`
- revision capture ms: `[0.9609460830688477]`
- revision restore ms: `[]`
- history bytes/commands/appends/navigation finishes/releases:
  `4416 / 2 / 2 / 2 / 0`; `canUndo=true`, `canRedo=false`
- family-specific mismatch count / changed regions: `0 / 0`
- frames/missed/peak resident: `7 / 0 / 23478272` bytes
- projected fragments / maximum / instance bytes: `1 / 1 / 112`

### `resize-crop-fill`

- brush processing, dab GPU, commit GPU, and event-to-submit ms: `[]`
- grid GPU ms: `[1.1141666618641466]`
- revision capture ms: `[1.641988754272461, 1.0609626770019531]`
- revision restore ms: `[0.7269382476806641, 1.043081283569336, 2.2439956665039062, 1.6820430755615234]`
- history bytes/commands/appends/navigation finishes/releases:
  `104448 / 2 / 2 / 4 / 0`; `canUndo=true`, `canRedo=false`
- family-specific mismatch count / changed regions: `0 / 2`
- frames/missed/peak resident: `1 / 0 / 22921216` bytes
- projected fragments / maximum / instance bytes: `0 / 0 / 0`

## Retained Evidence

- Final one-shot stdout: `.build/final-evidence-gate.stdout.log` (empty)
- Final one-shot stderr: `.build/final-evidence-gate.stderr.log`
- Final one-shot exit status: `.build/final-evidence-gate.exit` (`1`)
- Stage logs: `.build/slice3-slice0-functional.log`,
  `.build/slice3-slice1-functional.log`, `.build/slice3-swift-test.log`,
  `.build/slice3-xcodegen.log`, `.build/slice3-macos-build.log`,
  `.build/slice3-ipados-build.log`, and
  `.build/slice3-evidence-validator-build.log` plus
  `.build/slice3-strict-evidence.log`
- RED evidence: `.build/final-evidence-red.log` and
  `.build/final-evidence-runner-red.log`
- Focused GREEN evidence: `.build/final-evidence-history-green.log` and
  `.build/final-evidence-focused-green.log`
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
