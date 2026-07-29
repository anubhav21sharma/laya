# Brush Deposition Backend

**Status:** Stage 4 Acceptance Pending Physical Hardware And Manual Review

## Scope

This milestone records the commit-bound Stage 4 deposition evidence bundle.
Stage 4 replaces the generic compatibility stamp path and bounded wash with
the native compiled deposition backend for ink, dry media, glaze, marker,
airbrush, and erase.

## Automated Evidence

The committed Stage 4 gate is `scripts/verify-brush-stage4.sh`. It binds all
software evidence to one committed source tree, validates the exact 16
positive and 16 negative-control deposition scenes, and records its artifact
manifest under `.build/brush-deposition-artifacts/`.

Exact commit, test, build, analysis, scene, performance, and manifest results
are recorded here only after the clean committed gate has run.

## Physical Hardware Acceptance

The following profiles remain pending unless a committed gate run receives
separate physical evidence:

- reference M-series ProMotion iPad at 120 Hz;
- A14-class floor at 60 Hz;
- Pencil and Wacom input;
- memory-warning and suspend/resume recovery;
- sustained thermal drawing;
- true input-to-photon instrumentation.

Virtual and paravirtual Metal measurements are diagnostic only and never
claim `realtime120` or 60 Hz physical acceptance.

## Manual Brush Lab Acceptance

The 312 deterministic Brush Lab cards are exported headlessly with every
assessment unset. User appearance and input-quality review remains pending.
No visual baseline is created or promoted without explicit user approval.

## Product Boundary

Old Slice 4 pixel parity and bounded-wash behavior are intentionally not
acceptance targets. Stage 5 may tune dry-media behavior only after this engine
boundary is accepted. Stage 6 introduces wet interaction, pickup, smudge, and
Wet Mix from scratch.
