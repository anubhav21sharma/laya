# Slice 3: Transactions, Region Undo, Color, And Eraser

- **Status:** Pending Performance And Manual Acceptance
- **Date:** 2026-07-21
- **Implementation evidence commit:**
  `df14f9d0ae4b5a9992ed4e23e546d63a72c805ef`
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

## Environment And Provenance

- GPU: `Apple Paravirtual device`
- Operating system: `Version 26.5.2 (Build 25F84)`
- Logical processors: `8`
- Physical memory: `8589934592` bytes
- Build configuration: `Debug`
- Harness timestamp: `2026-07-20T22:53:10Z` through
  `2026-07-20T22:53:11Z`
- Every retained Slice 3 benchmark record identifies implementation commit
  `df14f9d0ae4b5a9992ed4e23e546d63a72c805ef`.

This device is a paravirtual GPU, so its real command-buffer timings are not a
stable real-Metal performance acceptance environment. The measurements below
are retained as exact diagnostics, not promoted or aggregated into a pass.

## Automated Evidence

The one allowed invocation of `./scripts/verify-slice3.sh` completed every
functional stage in fixed order:

- Slice 0 automated gate: passed.
- Slice 1 functional gate, including the Slice 0 regression: passed under its
  explicit functional-only performance override.
- Swift tests: `294 tests in 5 suites` passed.
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

- brush processing ms: `[0.18298625946044922, 0.07200241088867188]`
- dab GPU ms: `[0.8069583273027092]`
- grid GPU ms: `[0.48133333621080965, 0.5566666659433395]`
- commit GPU ms: `[1.1982500000158325]`
- event-to-submit ms: `[0.07200241088867188]`
- revision capture ms: `[1.4400482177734375]`
- revision restore ms: `[0.4349946975708008, 0.26595592498779297]`
- history: `4224` bytes, `1` command, `1` changed region
- frames/missed/peak resident: `4 / 0 / 22839296` bytes
- projected fragments / maximum / instance bytes: `1 / 1 / 112`

### `eraser-live-commit`

- brush processing ms: `[0.21505355834960938, 0.10502338409423828, 0.05698204040527344, 0.028967857360839844]`
- dab GPU ms: `[1.1300000041956082, 0.3182500076945871]`
- grid GPU ms: `[0.3565833467291668, 0.25275000371038914, 0.5130000063218176]`
- commit GPU ms: `[0.7272499933606014, 0.6698749930365011]`
- event-to-submit ms: `[0.10502338409423828, 0.028967857360839844]`
- revision capture ms: `[0.946044921875, 0.80108642578125]`
- revision restore ms: `[0.5840063095092773, 0.2770423889160156]`
- history: `8448` bytes, `2` commands, `1` changed region
- frames/missed/peak resident: `7 / 0 / 23068672` bytes
- projected fragments / maximum / instance bytes: `1 / 1 / 112`

### `region-undo-seam`

- brush processing ms: `[0.20694732666015625, 0.07903575897216797]`
- dab GPU ms: `[0.9480833250563592]`
- grid GPU ms: `[0.6470833322964609, 0.33366665593348444]`
- commit GPU ms: `[0.5552916700253263]`
- event-to-submit ms: `[0.07903575897216797]`
- revision capture ms: `[0.7320642471313477]`
- revision restore ms: `[0.3720521926879883, 0.28896331787109375]`
- history: `1792` bytes, `1` command, `2` changed regions
- frames/missed/peak resident: `4 / 0 / 22921216` bytes
- projected fragments / maximum / instance bytes: `2 / 2 / 224`

### `clear-undo`

- brush processing ms: `[0.23508071899414062, 0.07700920104980469]`
- dab GPU ms: `[1.0875416628550738]`
- grid GPU ms: `[0.408125008107163, 0.6517500005429611]`
- commit GPU ms: `[0.5898333329241723]`
- event-to-submit ms: `[0.07700920104980469]`
- revision capture ms: `[0.7719993591308594, 0.7148981094360352]`
- revision restore ms: `[0.5590915679931641, 0.5180835723876953]`
- history: `135296` bytes, `2` commands, `1` changed region
- frames/missed/peak resident: `4 / 0 / 22921216` bytes
- projected fragments / maximum / instance bytes: `1 / 1 / 112`

### `tiling-undo`

- brush processing ms: `[0.18799304962158203, 0.07092952728271484]`
- dab GPU ms: `[1.0848333331523463]`
- grid GPU ms: `[0.5696666630683467, 0.31004166521597654, 0.28862500039394945, 0.30462500581052154, 0.2775416651275009]`
- commit GPU ms: `[0.5953750078333542]`
- event-to-submit ms: `[0.07092952728271484]`
- revision capture ms: `[0.783085823059082]`
- revision restore ms: `[]`
- history: `4416` bytes, `2` commands, `0` changed regions
- frames/missed/peak resident: `7 / 0 / 23429120` bytes
- projected fragments / maximum / instance bytes: `1 / 1 / 112`

### `resize-crop-fill`

- brush processing, dab GPU, commit GPU, and event-to-submit ms: `[]`
- grid GPU ms: `[0.8782499935477972]`
- revision capture ms: `[1.6369819641113281, 1.7139911651611328]`
- revision restore ms: `[0.8919239044189453, 1.2350082397460938, 0.7929801940917969, 0.6959438323974609]`
- history: `104448` bytes, `2` commands, `2` changed regions
- frames/missed/peak resident: `1 / 0 / 22888448` bytes
- projected fragments / maximum / instance bytes: `0 / 0 / 0`

## Retained Evidence

- One-shot stdout: `.build/task10-slice3-gate.stdout.log`
- One-shot stderr: `.build/task10-slice3-gate.stderr.log`
- Stage logs: `.build/slice3-slice0-functional.log`,
  `.build/slice3-slice1-functional.log`, `.build/slice3-swift-test.log`,
  `.build/slice3-xcodegen.log`, `.build/slice3-macos-build.log`,
  `.build/slice3-ipados-build.log`, and
  `.build/slice3-benchmark-evaluation.log`
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
