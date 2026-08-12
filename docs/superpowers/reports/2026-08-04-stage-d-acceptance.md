# Stage D Color And Sparse Surface Acceptance Checkpoint

Status: **not accepted — Xcode UI gate passed; two clean aggregate runs and
qualifying profile/physical evidence pending**

Scope: Stage D Tasks 0 through 8 on the current-only native project and brush
cutovers. Stage E remains closed.

Stage D base revision: `ca5dff5`

The complete 29-route Xcode UI sequence now executes. Successful manifests are
bound to pushed implementation commits through `e8756ee`; all three rows pass
with stable semantic hashes and zero pending or ownership-accounting mismatch.
No final two-run aggregate acceptance manifest has been produced.

Execution date: 2026-08-13 (Asia/Kolkata)

## Decision

The locally executable implementation, package tests, Metal ownership and
allocation gates, product builds, broad regression boundary, app-route source
boundary, exact Xcode-hosted UI route, and independent review are complete.
Stage D is nevertheless **not accepted** because these mandatory boundaries
remain:

1. final-source native-wall evidence must still be captured on a qualifying
   native GPU host; the unchanged miss-fraction requirement is `<=1%`;
2. the final acceptance script still requires two clean-commit runs from fresh
   roots with stable semantics and no resource growth; and
3. physical iPad/Pencil/Wacom/ProMotion/thermal/memory-pressure evidence is not
   available.

The user approved the one required macOS UI Automation prompt. No sudo was
needed and no further XCTest authorization is pending. Unavailable qualifying
hardware remains nonblocking for implementation and local verification, but it
does not weaken the fail-closed acceptance contract.

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

The current reviewed serial acceptance inventories contain **656 tests** after
the final lifecycle and inventory regressions:

| Group | Result |
| --- | ---: |
| Color | 26 tests / 3 suites |
| Sparse sampling | 220 tests / 5 suites |
| Stroke lifecycle | 189 tests / 3 suites |
| Modes | 51 tests / 3 suites |
| Layers | 35 tests / 2 suites |
| Persistence/export | 36 tests / 4 suites |
| Negative controls | 99 tests / 4 suites |

The matrix covers independent color vectors, sparse seam/corner/page-table
selection, terminal failure and immediate reuse, every current periodic/radial
mode, one-through-eight-layer linear-premultiplied composition, exact schema-4
streaming, current-only rejection, stable identities, flattened output, and
real mutation controls. The post-fix app/renderer/acceptance/resize/mode/export
selection passed 100/100 in four suites. The final review-fix selection passed
104/104, including legacy evidence decoding, fail-closed ownership mismatch,
capture/export serialization, a global deadline, cancellation-insensitive
display-preparation retirement, deterministic gesture semantics, pending-stroke
quiescence, and retained resize-history ownership.

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

The corrective-program completion added ten suites and resolved the five
remaining Stage D brush-quality records without relaxing their graphite,
charcoal, or chisel thresholds. Independent review approved their explicit
removal. The current oracle is therefore exactly **2,206 tests in 120 suites**
with **0 known issues**, and the tracked Stage D baseline is intentionally
empty rather than regenerated from current output.

The first current-source measurement completed the full 2,206/120 inventory in
1,982.791 seconds, but correctly failed closed on one unreviewed, host-sensitive
natural-charcoal CPU-quartile observation. The exact end-to-end artifact test
then passed in isolation in 402.504 seconds on the same source. The required
complete rerun passed all **2,206 tests in 120 suites** in **1,840.787 seconds**
with zero issues, and the strict verifier reported:

```text
Swift Testing baseline verified: 0 complete issue records.
```

The passing broad log SHA-256 is
`45e1a13aec58c192f1243d2f36296cd4867f9d689b85f73277a05a683f7088e8`;
the intentionally empty Stage D baseline SHA-256 is
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
The transient observation was not added to the baseline.

An earlier clean-root aggregate attempt exposed a separate reproducibility
defect before acceptance: nine CLI subprocess cases looked only in the
repository's default `.build/debug` directory and could not find the executable
in the acceptance runner's isolated SwiftPM scratch path. The tests now resolve
`layabrush-convert` beside their SwiftPM resource bundle. A nondefault fresh
scratch run passed all 8 tests (10 parameterized cases).

The next fresh-root aggregate attempt at exact pushed commit `e8756ee` reached
every pre-package gate. Its focused groups passed **656 tests**, its complete
broad rerun passed **2,206 tests in 120 suites** in **1,903.055 seconds** with
zero issues, all macOS and iOS Simulator Debug/Release builds passed, and its
wall-clock runtime, accelerated runtime, and allocation probes passed. The
production wall record reported event-to-submit p95 **7,472,792 ns**, p99
**7,931,083 ns**, and **1 miss in 602 attributed frames** on the Apple
Paravirtual device. The run did not count as a clean aggregate because the
final package validator rejected valid producer evidence before reaching
XCTest.

That rejection exposed three producer/consumer contract mismatches. Mutating
sparse compositor plans are deliberately one-shot, so their production trace
correctly reports positive plan-cache misses with zero hits; the validator had
required a hit. The allocation probe accepts zero-work actual allocations at
or below its maximum, while the validator had required equality. The sampling
probe enforces bounded per-event acquire, preflight, completion, wait, and
Metal-submission allocations, while the validator had incorrectly required all
totals to be zero and could not tokenize the spaced metric arrays it produced.
The validator now shares the producer caps, checks totals with overflow-safe
event bounds, accepts positive cache activity through misses, and parses
bracketed fields fail-closed. The full clean-run evidence now emits a verified
12-scenario package manifest under the corrected validator, and the affected
acceptance/sparse matrix passes **81 tests in 2 suites**. Two complete fresh-root
runs of the resulting pushed commit are still required.

## Builds

The final source tree passed:

- `swift build -c release` in 70.22 seconds;
- `PatternSpikeMac` Debug `build-for-testing`, including the UI bundle;
- `PatternSpikeMac` Release;
- dual-architecture `PatternSpikePad` Debug for iOS Simulator; and
- dual-architecture `PatternSpikePad` Release for iOS Simulator.

The Debug/Release product and simulator build matrix sets
`CODE_SIGNING_ALLOWED=NO`. XCUIApplication has a separate Debug
`build-for-testing` root that uses Xcode's local ad-hoc **Sign to Run Locally**
identity; UI Automation cannot materialize an unsigned runner and requires no
developer certificate or external signing credential. The final build-log
hashes are listed under Evidence.

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

## Xcode UI route gate

The earlier worker stall was a stale `testmanagerd` authorization state. After
the user approved the macOS **Enable UI Automation** prompt, the signed test
runner launched the production app and executed the exact required method:

```text
StageDAppRouteUITests.testProductionControlsShortcutsAndPersistenceWriteEvidence
1 test passed, 0 failures, 145.050 seconds
```

The timestamped log proves active progress through real clicks, drags, key
events, accessibility assertions, evidence captures, and file operations. It
completed all 29 routes: 19 controls, 7 shortcuts, and 3 persistence routes.
Every scenario row passed with `pendingOwnershipCount=0` and
`snapshotOwnershipAccountingMismatchCount=0`. Save wrote a 528,086-byte
schema-4 project; reopen replaced the controller and reset history; export
wrote a 6,088-byte PNG with the required signature and matching flattened
content.

A second diagnostic run proved the acceptance wrapper's corrected signing and
build separation: a fresh locally ad-hoc signed `build-for-testing` root fed
`test-without-building`, and the exact test passed again with zero failures in
198.722 seconds. Its xcresult summary reports `result=Passed`, one total test,
one passed test, and no failures or skips. The wrapper timeout is 300 seconds,
which leaves bounded headroom over both measured healthy runs while preserving
fail-closed termination.

Four later successful manifests were compared directly. Their raw
macOS gesture streams contained different intermediate sample counts and
produced different exact raster hashes, as expected for accessibility-driven
mouse delivery, while each run independently proved exact undo/redo and
save/open/export equality. The cross-run semantic projection now hashes the
canonicalized stroke endpoints and state transitions rather than nondeterministic
intermediate delivery. All three app-route semantic hashes and all six compared
resource metrics are identical between the runs; both report zero pending and
zero ownership-accounting mismatch.

The initial authorized run exposed evidence races rather than a false hang:
capture could overlap pending stroke completion, and flattened export could
contend with display preparation. The recorder now drives renderer/controller
quiescence, serializes display preparation around capture/export, returns early
on a timed-out response, and reports durable resize undo-history snapshot
ownership separately from pending work. Focused regressions cover both pending
stroke capture and retained resize history. The definitive pre-commit
final-source run passed in 156.435 seconds after all review fixes, including the
timed-out task retirement quarantine. The requested post-commit run then passed
the exact pushed implementation revision `1810dce` in 145.050 seconds without
another authorization prompt. A later exact pushed `e8756ee` manual-approval
request also reused the persistent authorization and passed one test with zero
failures or skips in 158.444 seconds; its result bundle records the macOS device,
test timestamps, and final passed status.

This successful run proves the pushed implementation commit's Xcode route, but
it is not the final acceptance aggregate. The acceptance script must still run
twice from clean fresh roots and combine this route with the package, broad,
runtime, allocation, build, review, and cross-run comparison gates.

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

The prior independent re-review reported no remaining Critical or Important
issues for its source snapshot. A new review of the capture-quiescence fix
found no Critical issue and three Important issues: legacy evidence decoding,
fail-open display/history token classification, and a drain whose inactivity
timeout did not impose one global deadline. The fixes now default missing
legacy counters to zero, count inconsistent ownership as pending, classify
display submissions according to their actual lease-only ownership, and pass
one monotonic deadline through the full capture drain. Follow-up review then
found overlapping capture/export acquisition and timed-out display-preparation
retirement races. The final implementation serializes capture/export work,
quarantines timed-out preparation until it retires, suppresses replacement
scheduling during retirement, and schedules exactly once afterward. The final
independent re-review reported no Critical, Important, or Minor findings and
independently passed 49 focused tests. The review gate is complete.

## Evidence

- Broad log:
  `.build/brush-corrective-verification/stage-d-current-broad-zero.log`
  (`45e1a13aec58c192f1243d2f36296cd4867f9d689b85f73277a05a683f7088e8`)
- Stage D baseline: `Tests/Baselines/stage-d-known-issues.txt`
  (`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`)
- macOS Release build log: `.build/stage-d-mac-release-reviewed.log`
  (`b0c63202e1088d42f80a676f573ac5113be749ac89c84b59acf3d36aa101abe1`)
- iPad Simulator Debug build log: `.build/stage-d-pad-debug-reviewed.log`
  (`4cd1e336721bde3dccc11978d3ca5e7e20526d18fbb5aca9cccd2a080fb116a2`)
- iPad Simulator Release build log: `.build/stage-d-pad-release-reviewed.log`
  (`cff11876a13a1e0e4c91c42b13ed56dfc907a8c61c1f35ef49f46423ddc4d933`)
- Post-fix focused log:
  `.build/brush-corrective-verification/stage-d-final-focused.log`
  (104 tests / 4 suites passed)
- UI log:
  `.build/brush-corrective-verification/stage-d-ui-1810dce.log`
  (`87a73a87135e7af90e164ffd6a33c39a8c6ccb9e69098b6d4a4fe8ca3daaf065`)
- UI result: `.build/StageDAppRoutes-1810dce.xcresult`
  (1 passed test / 0 failures / 145.050 seconds)
- App-route manifest SHA-256:
  `daaf11076aa6e8c343c6c4791cd715b96456cbdf88a1155842267168b736b22c`
- Saved project SHA-256:
  `17162304f164bbf47c818bb48ed751c5b4ab6f52de685889dec0cb917a731dc9`
- Exported PNG SHA-256:
  `d42f50762ac7700f80adfd8b48a0ab14324a44c3f6551adbbf431a44a5dd5ac2`
- Independent review disposition SHA-256:
  `e90d443dde3cb86f8a950623a1b7e636eac47fa6b8930548acae178c0144ad62`

These execution artifacts are local and intentionally uncommitted.

## Exit boundary

Stage D remains open. To change this report to `accepted`, run the fail-closed
acceptance script twice from clean fresh roots on a qualifying native GPU host,
obtain identical semantic hashes and wall miss
fraction `<=1%`, and attach the required physical-device evidence. Xcode UI
Automation and every other locally executable software gate are now working;
the corrected package validator still requires two complete aggregate runs on
the exact pushed source revision.
