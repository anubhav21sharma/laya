# Archived External Brush-Engine Analyses

**Status:** Non-authoritative historical input

**Archived:** 2026-08-01

This directory preserves two externally produced analyses for provenance only.
They contain a mixture of confirmed observations, partially correct concerns,
unsupported inferences, and claims contradicted by the repository. They must
not be used as a specification, implementation plan, or acceptance checklist.

The active sources of truth are:

1. [`2026-08-01-brush-engine-corrective-report.md`](../../../reports/2026-08-01-brush-engine-corrective-report.md)
   for independently reproduced failures and validated architectural findings.
2. [`2026-08-01-brush-engine-corrective-program.md`](../../../plans/2026-08-01-brush-engine-corrective-program.md)
   for implementation order, ownership, tests, and completion gates.
3. The approved world-class brush-engine design and its explicit invariants.

Validated additions from these archived analyses have been restated in the
active report or plan without retaining the external narrative as authority.
Examples include linear-light color handling, explicit speed normalization,
timed emission, footprint-aware spacing, a compile-time backend registry, and
the fact that the live CPU stroke pipeline is currently serialized on the main
actor.

Claims intentionally not carried forward include: absence of undo, absence of
rake/bristle concepts, moving symmetry ahead of logical-dab generation,
universal mask-border clipping, destination sampling already being fully
wired, Krita always using one linear color path, and GPU symmetry being
effectively free. Any future use of an archived statement requires a fresh
code or primary-source verification.
