# Slice 2: Generalized Seam-Correct Tiling

**Status:** Pending Performance And Manual Acceptance

**Gate:** `./scripts/verify-slice2.sh`

**Implementation evidence commit:** `d940ce6920d83b68e27fe706f2f53082f450100a`

**Latest gate invocation:** `./scripts/verify-slice2.sh >.build/task10-gate.stdout.log 2>.build/task10-gate.stderr.log`

**Push:** Not performed

## Result

The generalized projection implementation remains functionally strong, but
Slice 2 is not accepted. The one-shot Task 10 gate completed the Slice 0/1
functional regression, 190 Swift tests, Xcode generation, both Debug builds,
all 26 negative controls in table order, and the first 25 positive Slice 2
scenes. The final positive `projected-long-stroke` scene then failed closed on
its real dab-GPU growth invariant. The gate printed no pass line and created
no benchmark JSON for that failed positive.

Manual Mac acceptance has not been performed and is not claimed. There is no
accepted Slice 1 performance baseline, so this milestone records:

```text
slice1Comparison: unavailable-user-waived
```

The waiver permits implementation to proceed; it does not waive Slice 2's
absolute performance budgets.

Post-run review hardened only gate verification semantics: negative stderr is
now byte-exact, manifest entries are canonically confined, and an accepted
baseline is read from a pinned private snapshot. Per the review instruction,
the full one-shot gate was not rerun. The measurements and failure above
remain the sole Task 10 gate evidence and are not upgraded by this hardening.

## Environment And Identity

- GPU: `Apple Paravirtual device`
- Logical processors: `8`
- Physical memory: `8,589,934,592 bytes`
- OS: `Version 26.5.2 (Build 25F84)`
- Configuration: `Debug`
- Benchmark commit for the current retained Task 10 records:
  `d940ce6920d83b68e27fe706f2f53082f450100a`
- Current positive records: `25`
- Current negative-control records: `26`
- Current final-positive `projected-long-stroke` benchmark: absent

The gate script itself was an uncommitted Task 10 working-tree change during
this run. The application and benchmark identity therefore correctly record
the last implementation commit, `d940ce6`, rather than claiming later gate or
milestone documentation as renderer provenance.

## Retained Evidence

- Slice 1 functional regression:
  `.build/slice2-slice1-functional.log`
- Explicit Swift test run:
  `.build/slice2-swift-test.log`
- Xcode generation:
  `.build/slice2-xcodegen.log`
- macOS Debug build:
  `.build/slice2-macos-build.log`
- Generic iPadOS Simulator Debug build:
  `.build/slice2-ipados-build.log`
- Task 10 gate stdout/stderr:
  `.build/task10-gate.stdout.log`, `.build/task10-gate.stderr.log`
- Positive scene families:
  `.build/slice2-artifacts/positive/<scene>/`
- Negative-control scene families:
  `.build/slice2-artifacts/negative-control/<scene>-negative-control/`
- Final negative long-stroke benchmark:
  `.build/slice2-artifacts/negative-control/projected-long-stroke-negative-control/projected-long-stroke-negative-control.benchmark.json`
- Final positive long-stroke stderr:
  `.build/slice2-artifacts/positive/projected-long-stroke/stderr.log`
- Preserved Task 10 stderr:
  `.superpowers/sdd/evidence/task10-paravirtual-long-stroke-failure-stderr.log`
- Earlier Task 9 preserved stderr:
  `.superpowers/sdd/evidence/task9-paravirtual-long-stroke-failure-stderr.log`
- Pre-review 26-pair log:
  `.build/task9-pairs-precommit.log`
- Final-implementation 25-pair Task 9 log:
  `.build/task9-final-pairs.log`
- Counter capability probe:
  `.build/task9-metal-counter-support.log`

Generated `.build/` content and `App/PatternSpike.xcodeproj/` remain ignored.
No retained diagnostic artifact is an accepted baseline.

## Scene Matrix And Artifact Contracts

All scenes use schema `3`, a `512 x 512` drawable, and the exact table order
below. The negative partner changes only the named first structural value from
`0` to `1`; the expected stderr is:

```text
HARNESS FAIL Tiling scene '<scene>-negative-control' tiling <tiling> cell none metric <metric>: expected equal 1, actual 0.
```

| # | Positive scene | Tiling raw | Tile | Diagnostic | Negative metric | Artifact family |
| ---: | --- | --- | --- | --- | --- | --- |
| 1 | generalized-grid | grid `0` | 256x256 | hardRound | oracleHoleCount | coverage-basic |
| 2 | halfdrop-interior | halfDrop `1` | 288x192 | hardRound | oraclePhantomCount | coverage-gridlines |
| 3 | halfdrop-edge | halfDrop `1` | 288x192 | hardRound | oracleHoleCount | coverage-gridlines plus exact canonical pixel `(0,0)` |
| 4 | halfdrop-corner | halfDrop `1` | 288x192 | hardRound | oraclePhantomCount | coverage-gridlines |
| 5 | brick-transpose | brick `2` | 288x192 | hardRound | transformMismatchCount | coverage-gridlines |
| 6 | mirror-x | mirrorX `3` | 256x256 | asymmetricCoverage | transformMismatchCount | diagnostic |
| 7 | mirror-y | mirrorY `4` | 256x256 | asymmetricCoverage | transformMismatchCount | diagnostic |
| 8 | mirror-xy | mirrorXY `5` | 256x256 | asymmetricCoverage | transformMismatchCount | diagnostic |
| 9 | rotational-generator | rotational `6` | 256x256 | asymmetricCoverage | transformMismatchCount | diagnostic |
| 10 | rotational-fixed-point | rotational `6` | 256x256 | hardRound | duplicateFixedPointWriteCount | coverage-basic |
| 11 | rotational-orientation | rotational `6` | 256x256 | asymmetricCoverage | transformMismatchCount | diagnostic |
| 12 | large-footprint | grid `0` | 64x96 | hardRound | oracleHoleCount | coverage-basic |
| 13 | asymmetric-footprint | rotational `6` | 256x256 | asymmetricCoverage | transformMismatchCount | diagnostic |
| 14 | canonical-coordinate-continuity | halfDrop `1` | 288x192 | canonicalCoordinates | coordinateContinuityMismatchCount | diagnostic |
| 15 | brush-local-coordinate-continuity | mirrorXY `5` | 256x256 | brushLocalCoordinates | coordinateContinuityMismatchCount | diagnostic |
| 16 | rectangular-tile | grid `0` | 320x192 | hardRound | oracleHoleCount | coverage-basic |
| 17 | noncentral-visible-cell-grid | grid `0` | 256x256 | hardRound | visibleCellCanonicalByteDelta | noncentral |
| 18 | noncentral-visible-cell-halfdrop | halfDrop `1` | 288x192 | hardRound | visibleCellCanonicalByteDelta | noncentral |
| 19 | noncentral-visible-cell-brick | brick `2` | 288x192 | hardRound | visibleCellCanonicalByteDelta | noncentral |
| 20 | noncentral-visible-cell-mirror-x | mirrorX `3` | 256x256 | hardRound | visibleCellCanonicalByteDelta | noncentral |
| 21 | noncentral-visible-cell-mirror-y | mirrorY `4` | 256x256 | hardRound | visibleCellCanonicalByteDelta | noncentral |
| 22 | noncentral-visible-cell-mirror-xy | mirrorXY `5` | 256x256 | hardRound | visibleCellCanonicalByteDelta | noncentral |
| 23 | noncentral-visible-cell-rotational | rotational `6` | 256x256 | hardRound | visibleCellCanonicalByteDelta | noncentral |
| 24 | metadata-tiling-switch | grid `0` | 256x256 | hardRound | canonicalByteDelta | metadata |
| 25 | projected-live-commit | halfDrop `1` | 288x192 | hardRound | previewCommitViolationCount | projected |
| 26 | projected-long-stroke | halfDrop `1` | 288x192 | hardRound | restampedInstanceCount | projected |

Artifact families require these exact nonempty files in each scene directory:

- `coverage-basic`: live screen, committed screen, canonical, three oracle
  PNGs, oracle metrics JSON, and benchmark JSON.
- `coverage-gridlines`: every `coverage-basic` artifact plus the grid-lines
  screen PNG.
- `diagnostic`: live screen, canonical, display-validation canonical/screen/
  grid-lines PNGs, three oracle PNGs, oracle metrics JSON, and benchmark JSON.
- `noncentral`: committed screen, canonical, and benchmark JSON.
- `metadata`: initial-, alternate-, and restored-tiling screens, committed
  screen, canonical, and benchmark JSON.
- `projected`: live screen, committed screen, canonical, and benchmark JSON.

Each directory also retains `stdout.log`; each negative directory retains its
exact `stderr.log`.

## Benchmark Schema

The evaluator requires and type-checks the complete schema-3 record surface:

- identity: `schemaVersion`, `timestampUTC`, `sceneName`, `hardware.gpuName`,
  `hardware.logicalProcessorCount`, `hardware.physicalMemoryBytes`,
  `operatingSystem`, `build.configuration`, `build.gitCommit`;
- base measurements: `frameCount`, `cpuEncodeMilliseconds`,
  `gpuMilliseconds`, `peakResidentBytes`;
- frame/path measurements: `brushProcessingMilliseconds`,
  `eventToSubmitMilliseconds`, `dabGPUMilliseconds`, `gridGPUMilliseconds`,
  `commitGPUMilliseconds`, `commitPendingMilliseconds`,
  `displayFrameBudgetMilliseconds`, `newInstanceCounts`,
  `totalStrokeInstanceCounts`, `missedFrameCount`;
- Slice 2 structure: `tilingRawValue`, `tileWidth`, `tileHeight`,
  `totalProjectedFragmentCount`, `maximumFragmentsPerFootprint`,
  `totalInstanceBytes`, `oracleHoleCount`, `oraclePhantomCount`,
  `oracleMaximumDelta`, `diagnosticMode`;
- long stroke: `longStrokeEarlyCPUP95Milliseconds`,
  `longStrokeLateCPUP95Milliseconds`,
  `longStrokeEarlyDabGPUP95Milliseconds`,
  `longStrokeLateDabGPUP95Milliseconds`,
  `longStrokeCPUMillisecondsPerFrameSlope`, and
  `longStrokeDabGPUMillisecondsPerFrameSlope`.

Missing fields, wrong types, nonfinite measurements, and nonpositive measured
durations fail closed. Projected bytes must equal fragment count times the
exact `96`-byte ABI stride.

## Current Final-Head Measurements

These are diagnostic values from the 25 positive records retained by the
one-shot Task 10 run. They are not a complete performance result. CPU and GPU
columns are exact minimum/maximum spans from `cpuEncodeMilliseconds` and
`gpuMilliseconds`; `n` is the number of entries.

| Scene | Fragments/max/bytes | Oracle H/P/D | Frames/missed | CPU ms (n; min...max) | GPU ms (n; min...max) | Peak bytes |
| --- | --- | --- | --- | --- | --- | ---: |
| asymmetric-footprint | 4/4/384 | 0/0/0 | 1/0 | 1; 0.09799003601074219...0.09799003601074219 | 1; 1.796750002540648...1.796750002540648 | 24,248,320 |
| brick-transpose | 3/3/288 | 0/0/0 | 1/0 | 5; 0.012040138244628906...0.10502338409423828 | 5; 0.4438333271536976...5.852499991306104 | 28,147,712 |
| brush-local-coordinate-continuity | 4/4/384 | 0/0/0 | 1/0 | 1; 0.05996227264404297...0.05996227264404297 | 1; 1.9435416616033763...1.9435416616033763 | 24,166,400 |
| canonical-coordinate-continuity | 3/3/288 | 0/0/0 | 1/0 | 1; 0.05900859832763672...0.05900859832763672 | 1; 1.7809999990276992...1.7809999990276992 | 24,117,248 |
| generalized-grid | 4/4/384 | 0/0/0 | 1/0 | 4; 0.01704692840576172...0.17595291137695312 | 4; 0.5451250035548583...8.092375006526709 | 28,049,408 |
| halfdrop-corner | 3/3/288 | 0/0/0 | 1/0 | 5; 0.010013580322265625...0.13494491577148438 | 5; 0.37058333691675216...0.8179583383025602 | 28,196,864 |
| halfdrop-edge | 3/3/288 | 0/0/0 | 1/0 | 5; 0.010013580322265625...0.10204315185546875 | 5; 0.416416660300456...8.957874990301207 | 28,246,016 |
| halfdrop-interior | 1/1/96 | 0/0/0 | 1/0 | 5; 0.007033348083496094...0.15807151794433594 | 5; 0.3474583354545757...6.516291672596708 | 28,164,096 |
| large-footprint | 48/48/4608 | 0/0/0 | 1/0 | 4; 0.016927719116210938...0.22900104522705078 | 4; 0.7861250051064417...9.574125011567958 | 26,607,616 |
| metadata-tiling-switch | 1/1/96 | n/a | 1/0 | 5; 0.010967254638671875...0.22995471954345703 | 5; 0.5341666692402214...6.007500007399358 | 27,721,728 |
| mirror-x | 2/2/192 | 0/0/0 | 1/0 | 1; 0.07104873657226562...0.07104873657226562 | 1; 1.5492499951506034...1.5492499951506034 | 28,426,240 |
| mirror-xy | 4/4/384 | 0/0/0 | 1/0 | 1; 0.06508827209472656...0.06508827209472656 | 1; 1.7420000076526776...1.7420000076526776 | 28,442,624 |
| mirror-y | 2/2/192 | 0/0/0 | 1/0 | 1; 0.06401538848876953...0.06401538848876953 | 1; 3.435624996200204...3.435624996200204 | 28,475,392 |
| noncentral-visible-cell-brick | 2/1/192 | n/a | 1/0 | 3; 0.012040138244628906...0.16605854034423828 | 3; 0.811500009149313...9.462541667744517 | 23,134,208 |
| noncentral-visible-cell-grid | 2/1/192 | n/a | 1/0 | 3; 0.01800060272216797...0.14400482177734375 | 3; 0.8974999946076423...7.379874994512647 | 23,150,592 |
| noncentral-visible-cell-halfdrop | 2/1/192 | n/a | 1/0 | 3; 0.0209808349609375...0.09799003601074219 | 3; 0.5949583282927051...8.170583329047076 | 23,035,904 |
| noncentral-visible-cell-mirror-x | 2/1/192 | n/a | 1/0 | 3; 0.010967254638671875...0.1690387725830078 | 3; 0.3771250048885122...0.8055833459366113 | 23,314,432 |
| noncentral-visible-cell-mirror-xy | 2/1/192 | n/a | 1/0 | 3; 0.012040138244628906...0.2199411392211914 | 3; 0.4997500072931871...0.8822083327686414 | 23,314,432 |
| noncentral-visible-cell-mirror-y | 2/1/192 | n/a | 1/0 | 3; 0.011920928955078125...0.1310110092163086 | 3; 0.4558750079013407...0.9030416695168242 | 23,248,896 |
| noncentral-visible-cell-rotational | 4/2/384 | n/a | 1/0 | 3; 0.011086463928222656...0.14793872833251953 | 3; 0.4376249999040738...6.348499999148771 | 23,314,432 |
| projected-live-commit | 33/3/3168 | n/a | 1/0 | 4; 0.033020973205566406...0.27501583099365234 | 4; 0.7696249958826229...9.775250000529923 | 26,853,376 |
| rectangular-tile | 4/4/384 | 0/0/0 | 1/0 | 4; 0.010013580322265625...0.1379251480102539 | 4; 0.32087499857880175...0.8508333412464708 | 28,098,560 |
| rotational-fixed-point | 1/1/96 | 0/0/0 | 1/0 | 4; 0.016927719116210938...0.27000904083251953 | 4; 0.6147500098450109...7.042291661491618 | 28,180,480 |
| rotational-generator | 2/2/192 | 0/0/0 | 1/0 | 1; 0.05805492401123047...0.05805492401123047 | 1; 1.942250004503876...1.942250004503876 | 28,442,624 |
| rotational-orientation | 2/2/192 | 0/0/0 | 1/0 | 1; 0.06794929504394531...0.06794929504394531 | 1; 1.4755000011064112...1.4755000011064112 | 24,166,400 |

The final negative-control long stroke reached its intended structural result
and retained a benchmark:

- frames/missed: `401 / 0`;
- fragments/max/bytes: `401 / 1 / 38,496`;
- CPU encode count/min/max:
  `404 / 0.0059604644775390625 / 0.18107891082763672 ms`;
- GPU count/min/max:
  `404 / 0.18687499687075615 / 10.576749991741963 ms`;
- early/late event-to-submit CPU p95:
  `0.03695487976074219 / 0.053882598876953125 ms`;
- early/late dab-GPU p95:
  `3.7318333343137056 / 2.405999999609776 ms`;
- CPU/dab-GPU slopes:
  `-0.00000435809162134099 / -0.00016277284100028376 ms/frame`;
- unique per-frame new-instance count: `{1}`;
- cumulative instance count: `1...401`;
- peak resident bytes: `26,935,296`;
- exact intended negative stderr:

```text
HARNESS FAIL Tiling scene 'projected-long-stroke-negative-control' tiling halfDrop cell none metric restampedInstanceCount: expected equal 1, actual 0.
```

## Gate Stop And Performance Status

The final positive emitted no benchmark. Its preserved stderr is:

```text
HARNESS FAIL Grid scene 'projected-long-stroke' counter invariant failed: Long-stroke dabGPU late p95 2.418750009383075 ms exceeds 1.7274437501328064 ms from early p95 1.502125000115484 ms.
SLICE2 GATE ERROR: positive Slice 2 scene failed: projected-long-stroke
```

The current internal Slice 1 diagnostic also measured the 500-new-dab GPU
maximum at `3.505000000586733 ms`, above the mandatory `< 3 ms` budget. The
full Slice 2 JSON performance evaluator was not reached because the final
positive scene failed first. Brush p95, full tiling-display p95, and the final
positive missed-frame/old-instance summaries therefore remain unaccepted;
the 25-row values above must not be combined into a synthetic pass.

Task 9 diagnosis found sporadic real command-buffer spans in the `5-9 ms`
range and one `48.7 ms` outlier on this paravirtual device. Only `2` of `6`
isolated baseline attempts reached the intended result. Autorelease-pool and
fixed-warmup experiments remained unreliable and were removed. No retry,
warmup, sample filtering, synthetic timing, or threshold relaxation is in the
product or Task 10 gate.

Metal counter sampling cannot replace the missing stable encoder timing here:

- stage-boundary sampling: unsupported;
- draw-boundary sampling: reported supported;
- available counter sets: empty.

## Provenance

The evidence history is deliberately not flattened into one accepted result:

1. `.build/task9-pairs-precommit.log` records all 26 negative-first pairs at a
   pre-review implementation state.
2. `.build/task9-final-pairs.log` records only the first 25 pairs at the
   intermediate implementation commit `af9293f`. The following isolated
   long-stroke probe failed before its intended structural assertion; the
   later review amendment produced `d940ce6` without retrying that unstable
   matrix.
3. Before Task 10, retained positives had mixed record provenance: 50 records
   from `af9293f52aacd5835edef1e4e6ff1f3f25ccf4dc` and the two long-stroke
   records from `6d0b219d77a6f749dd6128aa435e6ebe0f41cd76`.
4. The Task 10 gate cleared that directory and produced 25 final-HEAD positive
   records plus all 26 final-HEAD negative-control records at `d940ce6`.
   Because the last positive failed, there is still no single complete
   final-HEAD 52-scene acceptance set.

This is mixed logical provenance across retained diagnostic runs, not an
accepted baseline and not a final benchmark claim.

## Automated Gates Completed

- `PATTERN_SKIP_PERFORMANCE=1 ./scripts/verify-slice1.sh`:
  `SLICE1 FUNCTIONAL GATE PASS`.
- Slice 0 regression inside Slice 1: passed.
- Explicit `swift test`: `190 tests in 3 suites` passed.
- `(cd App && xcodegen generate)`: succeeded.
- macOS Debug build: `BUILD SUCCEEDED`.
- Generic iPadOS Simulator Debug build: `BUILD SUCCEEDED`.
- Exact negative controls: `26 / 26` matched in table order.
- Positive scenes before the stop: `25 / 26` passed with required artifact
  families.
- Final automated Slice 2 pass line: absent.

## Manual Mac Gate

Every item remains pending and unclaimed:

- [ ] all seven repeats look correct;
- [ ] central and noncentral drawing edit identical canonical content;
- [ ] half-drop and brick edges/corners show no holes or phantom copies;
- [ ] mirror and p2 asymmetric orientation is correct;
- [ ] tiling changes alter display without altering canonical pixels;
- [ ] preview/commit and cancel are visually stable;
- [ ] pan, cursor-anchored zoom, resize, stroke direction, and pointer
      alignment remain correct;
- [ ] long projected strokes remain responsive.

## Decisions

- Keep the absolute performance thresholds unchanged.
- Keep one-shot measurement semantics: no retries and no Slice 2 performance
  skip.
- Keep the Slice 1 functional override explicit and limited to Slice 1.
- Reject accepted baselines that resolve under mutable
  `.build/slice1-artifacts`, including symlink aliases and parent-directory
  symlink escapes from manifest entries.
- Pin the accepted manifest digest, copy every covered file into a verified
  private snapshot, and read comparisons only from that snapshot.
- Reverify both the original baseline and snapshot after the internal Slice 1
  run, immediately around evaluation, and immediately before any final pass
  output. Compare only matching hardware, OS, and Debug configuration.
- Require a negative control's stderr to contain exactly its expected line,
  with at most one conventional terminal newline.
- Do not promote current diagnostics into `current-slice1` or create an
  accepted baseline from them.
- Do not mark this milestone `Accepted` and do not push while performance and
  manual acceptance remain outstanding.

## Retrospective

- Negative-first ordering remains valuable: the final negative long stroke
  reached the exact structural failure before the positive exposed the
  environmental timing stop.
- Clearing the artifact root before the run prevents stale long-stroke JSON
  from masquerading as final evidence.
- Structural identity accounting remains stable even when paravirtual GPU
  timing is not: every measured negative-control long-stroke frame emitted one
  new instance and cumulative identity advanced exactly `1...401`.
- A checksum-protected baseline is only meaningful when every compared JSON
  record is covered by the manifest and the runtime identity matches.
- Performance evidence and manual visual acceptance are separate gates; one
  cannot substitute for the other.

## Acceptance Work Remaining

1. Run `./scripts/verify-slice2.sh` once on a stable real-Metal environment;
   do not retry a failed measurement.
2. Require all 26 negative controls and all 26 positives to complete at one
   final implementation commit with all required artifacts.
3. Require brush p95 `< 2 ms/frame`, 500-new-dab GPU maximum `< 3 ms`, tiling
   display p95 `< 2 ms`, missed-frame fraction `< 0.01`, exact new-instance
   identity, both long-stroke p95 growth limits, and both slopes
   `<= 0.001 ms/frame`.
4. If an accepted immutable Slice 1 baseline exists, verify `SHA256SUMS`
   before and after the Slice 1 regression, require matching hardware/OS/
   configuration, and require every compared p95 to remain within `15%`.
   Otherwise retain `slice1Comparison: unavailable-user-waived`.
5. Complete and record every manual Mac checklist item above.
6. Re-run scope, ignore, and hygiene audits; obtain final review.
7. Only after automated, performance, and manual gates pass, change this
   milestone to `Accepted`, commit the accepted evidence, and push.
