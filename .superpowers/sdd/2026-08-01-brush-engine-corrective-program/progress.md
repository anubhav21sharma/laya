# SDD ledger — plan: docs/superpowers/plans/2026-08-01-brush-engine-corrective-program.md

Baseline: a57e2c5
Baseline verification: `swift test` — 1297 tests in 70 suites passed (2026-08-01).
Workspace: normal `main` checkout, explicitly authorized by user and plan.
Unrelated preserved files: `.vscode/`, `brushes/procreate/1_FREE_Charcoal_Set.key`.
Preflight: renumbered alphanumeric Task 17A and following tasks to sequential
Tasks 18–28 for exact task-brief extraction; commit 136fdc0.
Implementation base: 136fdc0.
Task 1: complete (commits 136fdc0..30fe41e, review clean)
Task 2: fix round 1/5 (3 addressed, 0 open — blank Chisel false-green;
metric counterexamples; Metal silent pass; commits bedb765..4a3ad54)
Task 2: controller verification — required Metal run executed 12 tests with
the expected 7 issues across 5 defect tests; 18 valid 512x512 PNGs emitted.
Task 2: complete (commits 30fe41e..4a3ad54, review clean)
Task 3: fix round 1/5 (7 original findings plus live-authority/lifecycle
hardening addressed; commits 58d86f7..a536a63)
Task 3: fix round 2/5 (1 marker-only boundary-loss issue addressed;
commit f5c0d07)
Task 3: controller verification — 64 focused tests passed; macOS Debug build
succeeded; 10-second and accelerated offscreen production traces passed.
Task 3: broad-suite audit — 7 intentional Task 2 issues remain plus 6
ProfessionalBrushHarnessRunner artifact failures to isolate before final
acceptance; no Task 3 telemetry failures.
Task 3: complete (commits 4a3ad54..f5c0d07, review clean)
Stage A artifact regression: complete (commit 41f8ed5, review clean).
Root cause: Task 2 changed shared Stage 5 artifact scenes from 128x128 to
512x512. Shared fixtures restored; corrective tests now own private 512x512
canvases. Controller verification: 32 artifact/PNG tests passed; intentional
Task 2 baseline remains exactly 12 tests/7 issues.
Task 4: fix round 1/5 (1 Critical + 3 Important addressed; commit 6f4af5b).
Task 4: controller verification — 32 combined causal/hash/real-Metal tests
passed; build and diff checks clean. Technical Ink replay and endpoint defects
are green; 5 intentional Task 2 issues remain.
Task 4: complete (commits 41f8ed5..6f4af5b, review clean).
Task 5: fix round 1/5 — atomic downstream handoff (commit 625d16a).
Task 5: fix round 2/5 — sealed one-shot transactions (commit 316b13a).
Task 5: fix round 3/5 — single-owner/infallible handoff (commit 5824c9c).
Task 5: fix round 4/5 — deferred logical-dab callbacks (commit 874ef39).
Task 5: fix round 5/5 — generation-aware FIFO and batch checkpoints
(commit 2535909).
Task 5: BLOCKED after final review — 0 Critical, 2 Important remain:
unbounded consumed-prefix retention during a self-feeding callback drain, and
runtime telemetry callbacks can still reenter partially installed/tearing-down
stroke state. Required architectural replacement: one centralized bounded,
generation-aware, non-reentrant renderer event dispatcher for every public
callback. Do not proceed to Task 6 until separately authorized/replanned.
Task 5A: complete under
docs/superpowers/plans/2026-08-02-renderer-event-dispatcher.md (commits
886e758..66519a1; one fix round; independent review clean). Controller gate:
115 focused tests passed on Apple Paravirtual Metal, production allocation
probe=0, release build passed, callbacks centralized. Broad audit retains the
same 27 intentional brush/evidence failures tracked for later stages.
Task 5: unblocked and complete — Task 5A structurally resolves both remaining
Important findings with bounded fair delivery and post-transaction callbacks.
Task 6: in progress (base 66519a1).
Task 6: fix round 1/5 — formal review found 0 Critical, 4 Important,
3 Minor. Important: ordinary prediction does not subtract retained
actual/correction capacity; provenance mismatch occurs after coordinator or
fallback mutation; predicted began/ended bypass bounded admission; large dirty
footprints collapse to full surface/tile instead of exact prior footprint.
Additional fixes: multi-sample cadence parity, monotonic planned epochs, and
remove the accidentally tracked ignored task report.
Task 6: fix round 1/5 complete (commit 13c4e14); scoped re-review leaves
2 Important open. Estimated prediction does not subtract scheduler pending
capacity; invalid predicted/estimated endpoint inputs mutate receipt/runtime
telemetry before rejection and estimated updates lack moved-phase validation.
Task 6: fix round 2/5 in progress.
Task 6: fix round 2/5 complete (commit d537b43); scoped re-review clean
for Critical/Important findings.
Task 6: minor (deferred to Stage B final review) — constrained estimated
replay test does not directly exercise a non-empty retained predicted prefix.
Task 6: evidence caveat — allocation harness proves warmed ordinary,
authoritative estimated-correction, batch, and overload routes at 0, but not a
predicted sample awaiting an estimate; report wording must not overclaim it.
Task 6: controller verification — exact 90-test Task 6 gate and 53 adjacent
tests passed; release allocator probe self-test=1/production=0; release build,
callback-preservation and diff/status checks passed on Apple Paravirtual Metal.
Task 6: complete (commits b862378..d537b43; 2 fix rounds; no open
Critical/Important findings).
Task 7: in progress (base d537b43).
Task 7: complete (commit 8b35d46; Stage B acceptance report independently
clean; broad suite retained exactly 27 known issue records; zero actual replay,
bounded queues/storage, flat sustained work, lifecycle and failure reuse green).
Stage B: accepted at 8b35d46. See
docs/superpowers/reports/2026-08-02-stage-b-acceptance.md.
Stage C: accepted at ca5dff5 under the dedicated plan and ledger
docs/superpowers/plans/2026-08-02-stage-c-physical-input-dynamics.md and
.superpowers/sdd/2026-08-02-stage-c-physical-input-dynamics/progress.md.
Stage C exit evidence: focused 37/37, prescribed medium 400/400, broad 1,716
tests with exactly 27 frozen Stage B issues, zero warmed production
allocations, bounded 10-minute trace, debug/release stack gate green, and fresh
review with no Critical/Important findings.
Stage D: Task 0 complete — frozen preflight contracts cover
the six baseline full-canvas BGRA8 paint textures, independent encoded-BGRA8
color counterexamples, v1/v2/v3 archive/re-encode hashes, and the single
twelve-transition lifecycle inventory. No production behavior changed. See
docs/superpowers/reports/2026-08-04-stage-d-preflight.md. JIT authority is
docs/superpowers/plans/2026-08-04-stage-d-color-sparse-surfaces.md.
