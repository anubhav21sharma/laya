# Stage D Color And Sparse Surface Acceptance Checkpoint

Status: **not accepted — implementation verified; external evidence blocked**

Scope: Stage D Tasks 0 through 8 on the current-only native project and brush
cutovers. Stage E remains closed.

Stage D base revision: `ca5dff5`

Task 8 acceptance work remains intentionally uncommitted while this report is
not accepted. No commit, push, or final acceptance manifest was produced.

Execution date: 2026-08-11 (Asia/Kolkata)

## Decision

The locally executable implementation, package tests, Metal ownership and
allocation gates, product builds, broad regression boundary, app-route source
boundary, and independent review are complete. Stage D is nevertheless **not
accepted** because the remaining mandatory evidence cannot be produced on this
host:

1. the Xcode-hosted macOS UI worker does not materialize the test process, so
   zero XCUI tests execute and no app-route manifest is written;
2. the native-wall event-to-submit gate cannot be satisfied on the Apple
   Paravirtual GPU host; the unchanged requirement is `<=1%` on native hardware;
3. physical iPad/Pencil/Wacom/ProMotion/thermal/memory-pressure evidence is not
   available; and
4. the final acceptance script requires two clean-commit runs from fresh roots,
   which is intentionally impossible while the reviewed implementation remains
   an uncommitted dirty working tree.

The user directed work to continue without waiting for hardware review. That
made the unavailable physical evidence nonblocking for implementation and local
verification, but it does not weaken the fail-closed acceptance contract.

## Implemented Task 8 evidence boundary

Task 8 provides a typed Stage D manifest, command-line aggregator, fail-closed
acceptance script, production sparse/quiescence evidence, app-route evidence
writer, and Xcode UI route test. Required rows have stable scenario IDs,
deterministic seeds and semantic input traces, numeric or hash authorities,
producer identity, production backend identity, and typed status. Validation
rejects missing, duplicate, skipped, unknown, zero-test, nonproduction,
nonfinite, or failed evidence.

The final runner requires a clean Git worktree, removes any prior app-route
manifest before launching XCTest, binds every manifest to the exact commit, and
requires exactly one positive Swift Testing aggregate with no unreviewed issue.
It cannot pass by reusing a stale manifest or by executing zero filtered tests.

The hardened app route now records real normalized `StrokeSample` delivery from
`EditorSessionController`, including source, phase, capabilities, pressure, and
timing data. Deterministic repeatability uses a timing-independent quantized
semantic projection of those samples, rather than unstable OS timestamps.

Every command is observed independently: brush size, brush selection, ink
color, draw, erase tool, erase, undo, redo, layer add/lock/unlock/hide/show,
painted-layer selection, clear, undo-clear restoration, mode change, resize,
HUD, grid, numeric focus, save, open, and export. Clear is exercised against the
painted layer and undo must restore the exact nonblank flattened state.

Persistence evidence is cross-bound at three independent authorities:

- a native schema-4 layered archive identity/content hash over geometry, stable
  layer metadata, sorted sparse tile coordinates/bounds, and exact RGBA16F tile
  payloads;
- a flattened transparent BGRA8 hash plus a nonzero painted-pixel count; and
- independent ImageIO/CoreGraphics decoding of the exported PNG, whose BGRA8
  SHA-256 must equal the recorded flattened hash.

Save/open/export must preserve nonempty content, layer order and IDs, active
layer, configuration, size, native identity, and flattened output. The recorder
is rebound to the replacement controller after open; save history is present
before replacement and intentionally reset after reopen.

## Focused Stage D package matrix

The serial acceptance groups passed **637 tests**:

| Group | Result |
| --- | ---: |
| Color | 26 tests / 3 suites |
| Sparse sampling | 220 tests / 5 suites |
| Stroke lifecycle | 176 tests / 3 suites |
| Modes | 49 tests / 3 suites |
| Layers | 32 tests / 2 suites |
| Persistence/export | 36 tests / 4 suites |
| Negative controls | 98 tests / 4 suites |

The matrix covers independent color vectors, sparse seam/corner/page-table
selection, terminal failure and immediate reuse, every current periodic/radial
mode, one-through-eight-layer linear-premultiplied composition, exact schema-4
streaming, current-only rejection, stable identities, flattened output, and
real mutation controls. The final focused app-route recorder regression passed
1/1 after the semantic-route hardening; its broader bridge/color group had
already passed 8/8.

## Allocation and sustained accelerated trace

The optimized allocation oracle passed with zero post-warm application,
partition, and tile-lease allocation. It includes periodic and radial
continuation, stable lifecycle ownership, the current shared Metal command
queue, terminal lease return, and the complete 36,000-sample accelerated trace:

```text
ALLOCATOR PROBE STAGE D TILES PASS partition=20/0 lease=13/0
ALLOCATOR PROBE OFF-MAIN PASS application=0 workspace=0 main=0
  authoritative=0 estimated=0 prediction=0 packaging=0
  tile_partition=0 tile_lease=0
ALLOCATOR PROBE TEN-MINUTE TRACE PASS samples=36000
  hot_allocations=0/0 missed=0
ALLOCATOR PROBE PRODUCTION PASS allocations=0
```

Metal driver allocation remains separately reported and is not represented as
application allocation.

## Broad regression checkpoint

The final frozen-source serial run completed **2,134 tests in 110 suites** in
**1,030.215 seconds** and recorded exactly **5 issues**. The strict verifier
exited `0`:

```text
Swift Testing baseline verified: 5 complete issue records.
```

The reviewed Stage D baseline has SHA-256
`f6c364600d96606d191e3bb98a7c7185940c7096a5efd422d623bc8077213173`.
It was not regenerated from the run. The five records are only the separately
deferred Brush Corrective Tasks 21–23:

- Graphite 40 px support p50: `10` versus `>=20`;
- Graphite 40 px support p95: `10` versus `>=24`;
- Charcoal neutral-pressure changed pixels: `0` versus `>=512`;
- Charcoal neutral-pressure median alpha: `0` versus `>=0.10`; and
- Chisel right-angle protrusion: `14.416489` versus `<=4`.

No Stage D color, sparse storage, lifecycle, layer, persistence, export,
allocation, telemetry, manifest, or app-route package issue appears in the
broad result. The final broad log SHA-256 is
`0e2db14458d080a58928ed7bb15aeabfa55cb0c116f7dc4f276fdcaad01bfedc`.

## Builds

The final source tree passed:

- `swift build -c release` in 70.22 seconds;
- `PatternSpikeMac` Debug `build-for-testing`, including the UI bundle;
- `PatternSpikeMac` Release;
- dual-architecture `PatternSpikePad` Debug for iOS Simulator; and
- dual-architecture `PatternSpikePad` Release for iOS Simulator.

All Xcode commands set `CODE_SIGNING_ALLOWED=NO`, including the acceptance
script, so local signing state is not an implicit build prerequisite. The final
build-log hashes are listed under Evidence.

## Production wall-trace blocker

Prior production Release wall runs completed and wrote valid current artifacts,
but the event-to-submit miss fraction was above the unchanged `<=1%` gate on
the virtualized host. Observed fractions ranged from `3.57995%` to `16.66667%`.
CPU preparation was about `0.024 ms` p95, GPU completion about `2.740 ms` p95,
and queue high-water was zero, while event-to-submit was about `16.417 ms` p95.
The delayed interval therefore precedes renderer preparation rather than
showing CPU, GPU, or queue backlog.

No threshold was raised and no blocking wait was introduced. The wall gate
must be rerun on a native GPU/macOS host.

## Xcode UI route blocker

The final `test-without-building` attempt used the successfully built macOS UI
bundle and signing-disabled configuration. Xcode remained at “waiting for
workers to materialize”; the worker was idle with no app or test process, so it
was interrupted rather than allowed to wait indefinitely.

The result bundle reports one runner-level `Testing was canceled` failure,
**0 passed tests**, and no executed test body. Consequently no app-route
manifest exists. Package hosting/controller tests and a successful UI-target
build do not substitute for the exact `XCUIApplication` route.

## Environment and physical-evidence boundary

```text
Model: Apple Virtual Machine 1
Memory: 8 GB
GPU: Apple Paravirtual device
macOS: 26.5.2 (25F84)
Xcode: 26.6 (17F113)
Swift: Apple Swift 6.3.3
Target: arm64-apple-macosx26.0
```

No physical iPad, Apple Pencil, Wacom tablet, native ProMotion display, thermal
run, or device memory-pressure run was available. Pressure, tilt, azimuth,
roll, predicted/coalesced touch, hover, sustained 120 Hz, presentation,
thermal, and device-residency claims remain pending external evidence.

## Independent review

A fresh independent review covered the app-route hardening and acceptance
boundary. Its first pass found three Critical/Important issues: blank/self-
validated persistence, missing raw normalized-input capture, and missing
signing-disabled Xcode commands. All were corrected. Its adversarial follow-up
found command batching that allowed erase/clear no-ops and nondeterministic raw
timing in semantic hashes. Commands were separated, clear was bound to the
painted layer with exact undo restoration, and semantic strokes were quantized
without timestamps.

The final independent re-review reported **no remaining Critical or Important
issues**. This review gate is complete; it is no longer an acceptance blocker.

## Evidence

- Broad log: `.build/stage-d-broad-reviewed-final.log`
  (`0e2db14458d080a58928ed7bb15aeabfa55cb0c116f7dc4f276fdcaad01bfedc`)
- Stage D baseline: `Tests/Baselines/stage-d-known-issues.txt`
  (`f6c364600d96606d191e3bb98a7c7185940c7096a5efd422d623bc8077213173`)
- macOS Release build log: `.build/stage-d-mac-release-reviewed.log`
  (`b0c63202e1088d42f80a676f573ac5113be749ac89c84b59acf3d36aa101abe1`)
- iPad Simulator Debug build log: `.build/stage-d-pad-debug-reviewed.log`
  (`4cd1e336721bde3dccc11978d3ca5e7e20526d18fbb5aca9cccd2a080fb116a2`)
- iPad Simulator Release build log: `.build/stage-d-pad-release-reviewed.log`
  (`cff11876a13a1e0e4c91c42b13ed56dfc907a8c61c1f35ef49f46423ddc4d933`)
- UI result: `.build/StageDAppRoutes.semantic.xcresult`
  (0 passed tests; runner canceled before materialization)

These execution artifacts are local and intentionally uncommitted.

## Exit boundary

Stage D remains open and Stage E must not start. To change this report to
`accepted`, run the fail-closed acceptance script twice from clean fresh roots
on a native GPU host with working Xcode UI automation, obtain identical
semantic hashes and wall miss fraction `<=1%`, and attach the required physical-
device evidence. The independent review and all locally executable software
gates are already complete.
