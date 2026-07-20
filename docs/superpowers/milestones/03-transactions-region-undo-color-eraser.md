# Slice 3: Transactions, Region Undo, Color, And Eraser

- **Status:** Pending Performance And Manual Acceptance
- **Date:** 2026-07-21
- **Implementation evidence commit:**
  `df14f9d0ae4b5a9992ed4e23e546d63a72c805ef`
- **Review-hardening commit:**
  `9951b6a87d22f4820565e1b20037565f5929c733`
- **Branch:** `main`
- **Authorized base:** `e0c9adb`

## Scope Delivered

Slice 3 now has a strict schema-4 real-Metal acceptance harness and one-shot
gate for the editor behavior implemented by Tasks 1–9. The schema adds the six
focused programs and their structural assertions, while schema 1–3 decoding
and validation remain strict. `SliceThreeHarnessRunner` exercises the public
renderer transaction and revision APIs with synchronous harness waits instead
of adding test-only editing paths.

The six families prove colored drawing, live/committed erasing, separated
seam-region undo/redo, clear undo/redo, metadata-only tiling undo, and
top-left crop/transparent-fill resize undo/redo. Schema-4 benchmark records
require revision capture/restore times, retained history bytes and commands,
and changed-region count. All required numeric values are finite and
nonnegative.

The gate also corrects the stale Slice 2 projected-instance ABI assertion from
96 to 112 bytes. The four-fragment generalized-grid case is checked as exactly
448 bytes.

Post-review hardening replaces permissive file checks with a six-scene truth
table. It requires exact stdout, schema/program/scene identity, record keys,
structural counts, 112-byte instance accounting, exact PNG names/counts and
dimensions, and real PNG decoding. Stable-hardware evaluation requires every
brush, tiling, commit, event-to-submit, and missed-frame series with exact
sample counts, common hardware/OS/configuration/commit provenance, the Slice 1
500-dab record, and long-stroke instance identity before evaluating budgets.
The event-to-submit CPU stop now occurs after command-buffer submission and
includes the complete live-flush encode/submit span.

## Environment And Provenance

- GPU: `Apple Paravirtual device`
- Operating system: `Version 26.5.2 (Build 25F84)`
- Logical processors: `8`
- Physical memory: `8589934592` bytes
- Build configuration: `Debug`
- Harness timestamp: `2026-07-20T23:37:38Z` through
  `2026-07-20T23:37:39Z`
- Every retained Slice 3 benchmark record identifies implementation commit
  `9951b6a87d22f4820565e1b20037565f5929c733` and its exact schema-4
  program identity.

This device is a paravirtual GPU, so its real command-buffer timings are not a
stable real-Metal performance acceptance environment. The measurements below
are retained as exact diagnostics, not promoted or aggregated into a pass.

## Automated Evidence

The authorized post-review invocation of `./scripts/verify-slice3.sh`
completed every functional stage in fixed order:

- Slice 0 automated gate: passed.
- Slice 1 functional gate, including the Slice 0 regression: passed under its
  explicit functional-only performance override.
- Swift tests: `303 tests in 5 suites` passed, including 17 corrupted artifact
  fixtures, 9 incomplete/mixed performance fixtures, and 2 submission-timing
  seam tests.
- Xcode project generation: succeeded.
- macOS Debug build: `BUILD SUCCEEDED`.
- Generic iPadOS Simulator Debug build: `BUILD SUCCEEDED`.
- Slice 2 correctness replay: `26 / 26` scenes passed and wrote benchmark
  records. This does not claim Slice 2 performance or manual acceptance.
- Slice 3 exact negative controls: `6 / 6` failed for the named structural
  assertion, before their corresponding positives.
- Slice 3 positives: `6 / 6` passed, wrote `33` PNG artifacts and `6`
  schema-4 benchmark records.
- Artifact-family, schema-4 benchmark, provenance, finite/nonnegative,
  112-byte instance-ABI, and generalized-grid 448-byte checks: passed before
  the performance stop. Ignore and repository-hygiene checks passed
  separately during final review.

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
HARNESS FAIL Slice 3 scene 'colored-draw-negative-control' metric undoCanonicalByteDelta: expected equal 1, actual 0.
HARNESS FAIL Slice 3 scene 'eraser-live-commit-negative-control' metric undoCanonicalByteDelta: expected equal 1, actual 0.
HARNESS FAIL Slice 3 scene 'region-undo-seam-negative-control' metric undoCanonicalByteDelta: expected equal 1, actual 0.
HARNESS FAIL Slice 3 scene 'clear-undo-negative-control' metric redoCanonicalByteDelta: expected equal 1, actual 0.
HARNESS FAIL Slice 3 scene 'tiling-undo-negative-control' metric metadataCanonicalByteDelta: expected equal 1, actual 0.
HARNESS FAIL Slice 3 scene 'resize-crop-fill-negative-control' metric redoCanonicalByteDelta: expected equal 1, actual 0.
```

The eraser positive additionally enforces live/commit maximum byte delta
`<= 1`. The region positive enforces two separated changed regions; the
tiling positive enforces zero canonical delta; and all byte-exact undo/redo
and resize-dimension assertions passed.

## Exact Benchmark Diagnostics

The arrays below are the stored measurements in record order. They are not
percentiles, averages, filtered samples, warmups, retries, or synthetic
aggregates. Empty arrays mean that operation is not part of that scene.

### `colored-draw`

- brush processing ms: `[0.2720355987548828, 0.11897087097167969]`
- dab GPU ms: `[1.2400833365973085]`
- grid GPU ms: `[0.5533749936148524, 0.2988749911310151]`
- commit GPU ms: `[0.5900833348277956]`
- event-to-submit ms: `[0.30791759490966797]`
- revision capture ms: `[0.865936279296875]`
- revision restore ms: `[0.4420280456542969, 0.29098987579345703]`
- history: `4224` bytes, `1` command, `1` changed region
- frames/missed/peak resident: `4 / 0 / 22904832` bytes
- projected fragments / maximum / instance bytes: `1 / 1 / 112`

### `eraser-live-commit`

- brush processing ms: `[0.2529621124267578, 0.08797645568847656, 0.04589557647705078, 0.030994415283203125]`
- dab GPU ms: `[0.9146249940386042, 0.380749988835305]`
- grid GPU ms: `[0.4666250024456531, 0.2963333245133981, 0.3223749954486266]`
- commit GPU ms: `[0.7471249991795048, 0.48800000513438135]`
- event-to-submit ms: `[0.2460479736328125, 0.07605552673339844]`
- revision capture ms: `[0.9959936141967773, 0.6181001663208008]`
- revision restore ms: `[0.7120370864868164, 0.31495094299316406]`
- history: `8448` bytes, `2` commands, `1` changed region
- frames/missed/peak resident: `7 / 0 / 23134208` bytes
- projected fragments / maximum / instance bytes: `1 / 1 / 112`

### `region-undo-seam`

- brush processing ms: `[0.2930164337158203, 0.08606910705566406]`
- dab GPU ms: `[0.9867500048130751]`
- grid GPU ms: `[0.5409166624303907, 0.5603750032605603]`
- commit GPU ms: `[0.6158750038594007]`
- event-to-submit ms: `[0.23615360260009766]`
- revision capture ms: `[0.8310079574584961]`
- revision restore ms: `[0.5829334259033203, 0.3590583801269531]`
- history: `1792` bytes, `1` command, `2` changed regions
- frames/missed/peak resident: `4 / 0 / 22904832` bytes
- projected fragments / maximum / instance bytes: `2 / 2 / 224`

### `clear-undo`

- brush processing ms: `[0.2599954605102539, 0.13494491577148438]`
- dab GPU ms: `[1.3986666599521413]`
- grid GPU ms: `[0.5569583299802616, 0.6407500040950254]`
- commit GPU ms: `[0.9464583417866379]`
- event-to-submit ms: `[0.3489255905151367]`
- revision capture ms: `[1.3850927352905273, 0.6810426712036133]`
- revision restore ms: `[0.3669261932373047, 0.3540515899658203]`
- history: `135296` bytes, `2` commands, `1` changed region
- frames/missed/peak resident: `4 / 0 / 23035904` bytes
- projected fragments / maximum / instance bytes: `1 / 1 / 112`

### `tiling-undo`

- brush processing ms: `[0.24402141571044922, 0.10097026824951172]`
- dab GPU ms: `[1.5772500046296045]`
- grid GPU ms: `[0.498249995871447, 1.1440000089351088, 0.5344166711438447, 0.3452499950071797, 0.40208332939073443]`
- commit GPU ms: `[0.9293750044889748]`
- event-to-submit ms: `[0.3229379653930664]`
- revision capture ms: `[1.2350082397460938]`
- revision restore ms: `[]`
- history: `4416` bytes, `2` commands, `0` changed regions
- frames/missed/peak resident: `7 / 0 / 23461888` bytes
- projected fragments / maximum / instance bytes: `1 / 1 / 112`

### `resize-crop-fill`

- brush processing, dab GPU, commit GPU, and event-to-submit ms: `[]`
- grid GPU ms: `[0.9996666631195694]`
- revision capture ms: `[1.5000104904174805, 1.0451078414916992]`
- revision restore ms: `[0.9059906005859375, 0.7929801940917969, 0.6719827651977539, 0.786900520324707]`
- history: `104448` bytes, `2` commands, `2` changed regions
- frames/missed/peak resident: `1 / 0 / 22953984` bytes
- projected fragments / maximum / instance bytes: `0 / 0 / 0`

## Retained Evidence

- Post-review one-shot stdout: `.build/task10-review-gate.stdout.log`
- Post-review one-shot stderr: `.build/task10-review-gate.stderr.log`
- Stage logs: `.build/slice3-slice0-functional.log`,
  `.build/slice3-slice1-functional.log`, `.build/slice3-swift-test.log`,
  `.build/slice3-xcodegen.log`, `.build/slice3-macos-build.log`,
  `.build/slice3-ipados-build.log`, and
  `.build/slice3-evidence-validator-build.log` plus
  `.build/slice3-strict-evidence.log`
- RED/GREEN focused evidence: `.build/task10-review-red-artifact.log`,
  `.build/task10-review-red-performance.log`,
  `.build/task10-review-red-submission.log`, and the corresponding
  `green-*` logs
- Standalone final-HEAD six-pair root:
  `.build/task10-review-pairs-root.txt`
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
