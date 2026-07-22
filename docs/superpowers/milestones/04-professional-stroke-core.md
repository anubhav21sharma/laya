# Slice 4: Professional Stroke Core

- **Status:** Implementation Complete — Acceptance Pending Environment-Only Gates
- **Date:** 2026-07-22
- **Authorized base:** `9ae8c68dba36531b2eca165da23e5360663fc26d`
- **Branch:** `main`
- **Implementation evidence commit:** Pending until the verified source is
  committed below.
- **Gate:** `./scripts/verify-slice4.sh` (requires committed, clean source)
- **Governing design:**
  `docs/superpowers/specs/2026-07-22-professional-stroke-core-design.md`
- **Implementation plan:**
  `docs/superpowers/plans/2026-07-22-professional-stroke-core.md`

## Status Ruling

Tasks 1–13 are implemented and all available automated correctness work is
green. Slice 4 is not accepted: the committed-source gate is still pending
until the evidence commit below exists, while macOS UI automation permission,
subjective/manual interaction, stable physical-GPU timing, pressure-tablet,
and iPad hardware checks are unavailable in this environment.

The user authorized implementation to continue while earlier-slice
performance evidence remains unavailable. That authorization did not accept
or waive any earlier performance or manual gate.

## Tasks 1–13 Delivered

1. Deterministic legacy trace fixtures pin click, line, curve, pressure,
   seam, reflection, repeated-timestamp, and long-stroke behavior.
2. Brush Input V2 carries provenance, capabilities, optional orientation,
   validated pressure, and bounded world-space velocity.
3. Attributed interpolation and bounded stabilization preserve the legacy
   geometric wrapper while carrying dynamics inputs deterministically.
4. Validated brush recipes, mappings, taper, replay policy, and named random
   channels provide deterministic recipe/seed behavior.
5. One generator owns interpolation, spacing, dynamics, randomization, exact
   endpoints, and renderer dab production.
6. The projected-instance ABI is 128 bytes. Deterministic shape/grain assets
   preload through a validated resolver with bounded residency.
7. Ink and dry rendering support shape, hardness, affine footprints, and
   canonical or brush-local grain coordinates.
8. Flow is applied per dab and stroke opacity once per stroke; live and commit
   use the same premultiplied compositing contract.
9. Append-only, replay-tail, and bounded-whole-stroke transient state enforce
   sample, dab, instance, prediction, promotion, and epoch bounds.
10. Bounded wash uses fixed RGBA16Float working surfaces, capped local work,
    deterministic degradation, and history regions that include the wash
    halo.
11. Four draw anchors and a dedicated eraser are integrated through immutable
    pointer-down recipe/seed capture, native input adaptation, and the compact
    UI picker.
12. Schema 5 records recipe, seed, attributed traces, material, replay mode,
    bounds, asset, wash, and material timing metrics. The real-Metal runner
    drives `GridRenderer`, writes live/committed/canonical PNGs, records
    measured counters and digests, and fails negative controls. Its audits
    include legacy parity, pressure, same/different seed, shape/hardness,
    assets, grain modes, taper, prediction replacement, stale epochs,
    cancel/failure preservation, history, long-stroke bounds, and a real
    four-anchor by seven-tiling noncentral draw/erase matrix.
13. The final regression pass adds exact recipe-specific GPU/CPU seam support,
    an independent negative control for every governing harness family,
    exact identified 500-new-dab stress-frame evidence, deterministic
    full-tile wash degradation beyond the region metadata cap, updated
    128-byte ABI gates, sanitizers, app builds/analyzers, UI smoke coverage,
    and two independent code-review passes.

No Slice 5 serialization, document-format, editable brush-library, layer, or
selection-transform surface is claimed.

## Verification Results Run On 2026-07-22

These pre-commit results were obtained from the reviewed Slice 4 worktree. The
clean committed-source gate result is recorded separately after the evidence
commit is created:

- `swift test --no-parallel`: `480 tests in 9 suites` passed.
- The real eight-scene Slice 4 runner, every independent negative family,
  exact four-anchor by seven-tiling recipe seam matrix, and stress-frame tamper
  cases passed in `93.216s`.
- The focused ASan selection passed `98 tests in 4 suites`.
- The focused TSan selection passed `98 tests in 4 suites`.
- Expected-trap subprocess tests were intentionally excluded from sanitizer
  selections because their successful behavior is process termination; they
  remain covered by the unsanitized full suite.
- `./scripts/bootstrap.sh`: succeeded with XcodeGen `2.46.0`.
- PatternSpikeMac Debug build and static analysis: `ANALYZE SUCCEEDED`.
- PatternSpikePad generic iOS Simulator Debug build and static analysis:
  `ANALYZE SUCCEEDED`.
- PatternSpikePad installed and launched successfully on an iPad Pro 13-inch
  (M5) iOS 26.5 simulator, and its current editor layout rendered.
- The repository configures no Swift formatter or linter. `git diff --check`,
  shell syntax checks, and JSON validation passed.
- Two independent final reviews found and closed exact-seam, negative-matrix,
  stress-frame identity, wash metadata, and ABI-gate gaps. The final focused
  re-review reported no actionable findings.

The full `./scripts/verify-slice4.sh` result is deliberately absent here until
the gate can run from the required clean committed source.

## UI Verification

The current macOS app build was exercised through native accessibility and
screen capture:

- all four draw anchors selected and rendered visibly distinct strokes;
- the dedicated eraser removed pixels and drawing resumed afterward;
- changing brush size from 20 to 25 pixels updated the brush cursor's reported
  diameter and left clear, tools, tiling, and drawing responsive;
- width and height fields accepted numeric input without firing tiling
  shortcuts, and resizing preserved the documented top-left crop/fill rule;
- grid visibility, every one of the seven tiling selectors, clear, undo/redo
  buttons and keyboard shortcuts, and the tilde debug HUD all worked;
- a seam-crossing reference stroke was visually scanned in all seven tilings;
  no hole or phantom was observed, with the exact GPU/CPU oracle providing the
  non-subjective acceptance check;
- bounded wash rendered without freezing interaction; and
- the app was returned to its default 256 by 256 Grid, 20-pixel Technical Ink
  state after the sweep.

The signed macOS UI-test app and runner built and launched, but macOS denied
Developer Tool automation to `com.anubhav.patternspike.uitests.xctrunner` and
input-event authorization to `com.openai.codex`. XCTest timed out while
enabling automation mode before discovery, so exactly zero UI test methods
executed. The result bundle is
`.build/PatternSpikeMacUITests-Signed-2.xcresult`. Security/TCC settings were
not changed.

## Performance Status

The available GPU identifies as `Apple Paravirtual device`. Correctness,
bounds, provenance, and malformed evidence must still fail closed. Stable
material/GPU timing is explicitly pending and must not be promoted to a pass.
After a committed-source run, the validator is expected to return status `2`
(`PERFORMANCE PENDING`) on this GPU if all correctness stages pass.

## Task 13 Handoff — Not Accepted

- [ ] Create the Slice 4 implementation evidence commit, run
      `./scripts/verify-slice4.sh` from clean committed source, and record the
      exact result and artifact provenance below.
- [x] Run every configured formatting/lint equivalent and record that no Swift
      formatter/linter is configured.
- [x] Run approved ASan and TSan non-crash suites and record the expected-trap
      exclusion.
- [ ] Run macOS UI automation. Blocked by explicit Developer Tool/input-event
      TCC denial before XCTest discovery; signed build and result bundle are
      retained.
- [x] Complete two final code reviews against the design and plan, including
      allocation, epoch ordering, premultiplied math, ABI accounting, caps,
      fallback diagnostics, transaction ordering, harness truth, and Slice 5
      leakage.
- [ ] Complete the human-only Mac residue: pressure-tablet input, held-space
      pan/zoom cursor feel, temporal opacity/taper flash observation, and
      subjective long-stroke feel. No pressure tablet or human operator was
      available; automated UI and exact renderer checks above passed.
- [ ] Run stable physical-GPU performance evidence. The only GPU identifies as
      `Apple Paravirtual device`; its timing is diagnostic and cannot count as
      acceptance evidence.
- [ ] Run tablet-specific input and iPad hardware/Pencil checks. The simulator
      build launched, but no iPad or Pencil hardware was available.
- [ ] Record the final evidence commit and artifact provenance before any
      acceptance decision.

Every available Task 13 correctness and integration check is complete. The
remaining unchecked items require OS authorization, human/pressure input, or
physical hardware and remain explicit acceptance gates rather than
implementation blockers.

The implementation is packaged as one evidence commit because Tasks 1–13
were already integrated in the uncommitted worktree when final verification
began. Splitting the reviewed state afterward would create artificial
intermediate commits that were never independently built or gated.
