# Compiled Symmetry Phase 1

- **Status:** Phase 1 Complete
- **Date:** 2026-07-23
- **Branch:** `main`
- **Governing specification:**
  `docs/superpowers/specs/2026-07-23-compiled-periodic-radial-symmetry-design.md`
- **Implementation plan:**
  `docs/superpowers/plans/2026-07-23-compiled-symmetry-foundation.md` (was
  untracked during the recorded verification; included in the final Phase 1
  documentation set)
- **Phase implementation range:** `c27bc2d^..354deb4`

## Status Ruling

Compiled symmetry Phase 1 is complete. The seven existing rectangular modes
retain their raw values, JSON representation, CPU geometry, canonical raster
bytes, shader behavior, and public `TilingKind` spelling while production now
receives one validated `CompiledSymmetry`. The full Swift suite and both app
targets pass. The independent oracle remains descriptor-free, all 22
real-Metal positive/negative scene pairs behave as designed, and all 123
post-refactor PNGs are byte-identical to the pre-refactor baseline.

## Implementation Commits

| Task | Commit | Subject |
| --- | --- | --- |
| 1 | `c27bc2da410641ab250142105946dafd8ae38d65` | `feat(symmetry): compile legacy descriptors` |
| 2 | `3a1c63e742888f271edb56ebb63943b134acc6ba` | `refactor(symmetry): use rectangular kernel` |
| 3 | `ff251c0fafed521059715a09225502d314c1ea9c` | `refactor(symmetry): drive projection policy` |
| 4 | `ddaacaeb1f1bf43548845d6656bc866d3049ea9e` | `feat(metal): dispatch compiled symmetry family` |
| 5 | `354deb40d830db2d8c52fa09c274368689aff5b8` | `test(symmetry): prove legacy parity` |

## Stable Raw-Value Contracts

Only the selector and document configuration are serialized.
`CompiledSymmetry` is a closed runtime value and is not `Codable`.

### Document domain

| Value | Identifier |
| ---: | --- |
| 0 | `SymmetryDocumentDomainID.periodic` |
| 1 | `SymmetryDocumentDomainID.finite` |

### Kernel family

| Value | Identifier |
| ---: | --- |
| 0 | `SymmetryKernelFamily.rectangular` |
| 1 | `SymmetryKernelFamily.triangular` |
| 2 | `SymmetryKernelFamily.radial` |

### Legacy preset and Metal wire

| Value | Stable preset | Legacy spelling |
| ---: | --- | --- |
| 0 | `SymmetryPresetID.grid` | `TilingKind.grid` |
| 1 | `SymmetryPresetID.halfDrop` | `TilingKind.halfDrop` |
| 2 | `SymmetryPresetID.brick` | `TilingKind.brick` |
| 3 | `SymmetryPresetID.mirrorX` | `TilingKind.mirrorX` |
| 4 | `SymmetryPresetID.mirrorY` | `TilingKind.mirrorY` |
| 5 | `SymmetryPresetID.mirrorXY` | `TilingKind.mirrorXY` |
| 6 | `SymmetryPresetID.rotational` | `TilingKind.rotational` |

`TilingKind` is a typealias of `SymmetryPresetID`. The selector tests prove
that `JSONEncoder` emits the same bare numeric value and `JSONDecoder` accepts
it. Harness schema tests decode all raw `tiling` values `0...6`, round-trip the
numeric field, preserve the exact top-level schema, and emit no descriptor or
family fields.

## Descriptor Compilation And Validation

`SymmetryDescriptorCompiler.compile` first validates width and height in this
order:

1. finite;
2. integer-valued;
3. within `64...4096`.

It returns typed `SymmetryDescriptorError` values for non-finite,
non-integer, and out-of-range dimensions before constructing a descriptor.
Every successful descriptor includes its preset, periodic domain, family,
isometries, ownership, display program, raster metric, export capability, and
cost bound.

| Preset | Compiled phase/reflection/images | Coincident policy |
| --- | --- | --- |
| Grid | Identity image | Byte-equal only |
| Half Drop | X-indexed Y phase `[0, 0.5]`; identity image | Byte-equal only |
| Brick | Y-indexed X phase `[0, 0.5]`; identity image | Byte-equal only |
| Mirror X | Alternating X reflection; identity image | Byte-equal only |
| Mirror Y | Alternating Y reflection; identity image | Byte-equal only |
| Mirror XY | Alternating X and Y reflection; identity image | Byte-equal only |
| Rotational | Identity then tile-centred half-turn image | Half-turn-invariant coverage |

The compiler is the only production Phase 1 `switch presetID`. The complete
descriptor is built in `TilingStrategy.init`, before projection or rendering
receives the strategy.

## Compatibility Facade, Geometry, And Projection

`TilingStrategy` retains `kind`, `tileSize`, `CellIndex`, `TilingImage`, the
legacy initializer, precondition strings, and half-open boundary behavior. It
stores the compiled value once and delegates `cell`, `images`, and
`displayFold` to `RectangularSymmetryKernel`.

The kernel reads the compiled translation basis, phase program, alternating
reflection axes, and isometry table. It retains deterministic
row/column/ordinal ordering and the prior numeric helper implementation.
There is no preset switch in either the facade or kernel.

`TilingProjection` always removes byte-equal candidates. Coverage-equivalent
removal occurs only when the compiled periodic domain declares
`.halfTurnInvariantCoverage` and the evaluated footprint declares
`.halfTurnInvariant`. The former `strategy.kind == .rotational` name check is
absent.

## Metal ABI And Dispatch

The former trailing padding word now carries the append-only family selector.
No existing field moved.

| `PatternGridFrameUniforms` property | Value |
| --- | ---: |
| Size | 56 bytes |
| Stride | 56 bytes |
| Alignment | 8 bytes |
| `drawableSize` offset | 0 |
| `worldCenter` offset | 8 |
| `tileSize` offset | 16 |
| `zoom` offset | 24 |
| `gridLineWidth` offset | 28 |
| `showGridLines` offset | 32 |
| `liveVisible` offset | 36 |
| `tilingKind` offset | 40 |
| `diagnosticMode` offset | 44 |
| `compositeMode` offset | 48 |
| `symmetryFamily` offset | 52, formerly padding |

`GridRenderer` feeds the compiled display program's `presetWireID` and family
raw value. Metal rejects unsupported families before entering the unchanged
rectangular `tilingKind` switch; the invalid mapping remains visibly magenta.
No descriptor compiler call occurs in the renderer hot path.

## Focused Swift Evidence

The task reports recorded these exact commands and results:

| Command | Result |
| --- | --- |
| `swift test --filter SymmetryDescriptorCompilerTests` | Passed 4 tests, including 7 preset arguments |
| `swift test --filter RectangularSymmetryKernelParityTests` | Passed 4 characterization tests before and after the move |
| `swift test --filter TilingStrategyTests` | Passed 18 tests |
| `swift test --filter TilingProjectionTests` | Passed 21 tests after Task 3 |
| `swift test --filter TilingCoverageOracleTests` | Passed 17 tests after Task 5 |
| `swift test --filter ShaderABILayoutTests` | Passed 7 tests |
| `swift test --filter ReflectedRotationalShaderTests` | Passed 6 tests |
| `swift test --filter TranslationTilingShaderTests` | Passed 4 tests |
| `swift test --filter RendererRasterOperationTests` | Passed 13 tests |
| `swift test --filter compiledDescriptorsMatchIndependentOracleAcrossLegacyMatrix` | Passed one 420-case matrix test |
| `swift test --filter HarnessSceneTests` | Passed 80 tests |

The Task 2 report recorded that the repository's reused SwiftPM runner could
terminate with signal 11 during intentional-trap subprocess tests. Tasks 3–6
used absent scratch paths; the fresh full suites completed normally. No
assertion failure or production change was hidden by that earlier runner-state
issue.

## Complete Regression Gate

Run from the reviewed checkout:

```bash
swift test --scratch-path .build/symmetry-task6-fresh --no-parallel
```

Result: exit `0`; `499 tests in 10 suites` passed with zero failures in
`144.677 seconds`.

```bash
./scripts/bootstrap.sh
```

Result: exit `0`; XcodeGen `2.46.0` generated
`App/PatternSpike.xcodeproj`.

```bash
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  build CODE_SIGNING_ALLOWED=NO
```

Result: exit `0`; `** BUILD SUCCEEDED **`.

```bash
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedDataPad \
  build CODE_SIGNING_ALLOWED=NO
```

Result: exit `0`; both simulator architectures and Metal compiled;
`** BUILD SUCCEEDED **`.

The final source-boundary command was:

```bash
if rg -n "switch (kind|presetID)" \
  Sources/PatternEngine/TilingStrategy.swift \
  Sources/PatternEngine/RectangularSymmetryKernel.swift
then
  exit 1
fi
if rg -n \
  "CompiledSymmetry|CompiledIsometry|CompiledOwnership|CompiledDisplayProgram" \
  Sources/PatternEngine/Verification/TilingCoverageOracle.swift
then
  exit 1
fi
git diff --check
```

Result: exit `0` with no output. Both negative searches were empty and the
complete dirty-worktree diff had no whitespace errors.

## Independent Oracle Evidence

- `TilingCoverageOracle.swift` is unchanged across the Phase 1 implementation
  range.
- Its source continues to accept `tiling: TilingKind` and contains none of
  `CompiledSymmetry`, `CompiledIsometry`, `CompiledOwnership`, or
  `CompiledDisplayProgram`.
- The source guard passes in `TilingCoverageOracleTests`.
- The deterministic 420-case matrix compares exact coverage,
  canonical-coordinate, and brush-local bytes across all seven presets, two
  repeat sizes, five affine transforms, two footprints, and supersampling
  `1`, `2`, and `4`.
- The production side compiles and projects through
  `TilingStrategy`/`TilingProjection`; the independent oracle receives only
  the stable selector.

## Real-Metal Scene Matrix

All scenes used the existing macOS production binary and independent harness
contract. Every positive exited zero with `HARNESS PASS`; every paired
negative exited nonzero with a typed `HARNESS FAIL`.

| Scene | Positive | Negative control metric |
| --- | --- | --- |
| `generalized-grid` | Pass | `oracleHoleCount` |
| `halfdrop-interior` | Pass | `oraclePhantomCount` |
| `halfdrop-edge` | Pass | `oracleHoleCount` |
| `halfdrop-corner` | Pass | `oraclePhantomCount` |
| `brick-transpose` | Pass | `transformMismatchCount` |
| `mirror-x` | Pass | `transformMismatchCount` |
| `mirror-y` | Pass | `transformMismatchCount` |
| `mirror-xy` | Pass | `transformMismatchCount` |
| `rotational-generator` | Pass | `transformMismatchCount` |
| `rotational-fixed-point` | Pass | `duplicateFixedPointWriteCount` |
| `rotational-orientation` | Pass | `transformMismatchCount` |
| `asymmetric-footprint` | Pass | `transformMismatchCount` |
| `canonical-coordinate-continuity` | Pass | `coordinateContinuityMismatchCount` |
| `brush-local-coordinate-continuity` | Pass | `coordinateContinuityMismatchCount` |
| `noncentral-visible-cell-grid` | Pass | `visibleCellCanonicalByteDelta` |
| `noncentral-visible-cell-halfdrop` | Pass | `visibleCellCanonicalByteDelta` |
| `noncentral-visible-cell-brick` | Pass | `visibleCellCanonicalByteDelta` |
| `noncentral-visible-cell-mirror-x` | Pass | `visibleCellCanonicalByteDelta` |
| `noncentral-visible-cell-mirror-y` | Pass | `visibleCellCanonicalByteDelta` |
| `noncentral-visible-cell-mirror-xy` | Pass | `visibleCellCanonicalByteDelta` |
| `noncentral-visible-cell-rotational` | Pass | `visibleCellCanonicalByteDelta` |
| `metadata-tiling-switch` | Pass | `canonicalByteDelta` |

Artifact locations:

- positives:
  `.build/symmetry-phase1-artifacts/positive/`;
- negative controls:
  `.build/symmetry-phase1-artifacts/negative-control/`;
- typed negative summary:
  `.superpowers/sdd/task-5-metal-negative-metrics.log`;
- pre-refactor manifest:
  `.build/symmetry-phase1-legacy-baseline.sha256`;
- post-refactor manifest:
  `.build/symmetry-phase1-current.sha256`.

The matrix contains 22 positive directories, 22 negative-control directories,
and 123 positive PNGs. Both manifests contain 123 lines, and
`diff -u` produces no output. Canonical raster bytes and rendering are
therefore byte-identical to the pre-refactor fixture. The metadata-switch
pair separately proves that changing the preset remains metadata-only.

## Dirty-Checkout Provenance

The checkout retained unrelated user modifications in app, app-test,
EditorCore, and MetalRenderer-test files and the untracked `.vscode/`
directory. The implementation plan was untracked during the recorded
verification and is included in the final Phase 1 documentation set; unrelated
user modifications and `.vscode/` remain uncommitted. Ignored build and
evidence artifacts and SDD records were also preserved.

Strict clean-source slice wrappers were not run because their deliberate
provenance gate would reject that preserved dirty checkout. Task 5 instead
used the plan's exact direct scene command; no wrapper or validator was
weakened. Each of the 22 benchmark records embeds production commit
`ddaacaeb1f1bf43548845d6656bc866d3049ea9e` and configuration `Debug`.
Task 5's subsequent `354deb4` commit changes tests only. The direct logs,
typed negative failures, benchmark records, and byte manifests retain the
scene-level provenance.

## Governing-Spec Review

| Question | Answer | Evidence |
| --- | --- | --- |
| 1. Are raw values `0...6` unchanged? | Yes | Swift and C wire declarations and append-only tests pin every value. |
| 2. Does Codable still emit the same numeric values? | Yes | Selector and harness schema encode/decode tests pass for raw values `0...6`. |
| 3. Are all seven modes compiled from named descriptors? | Yes | The cold-path compiler exhaustively maps all seven named cases to the descriptor table above. |
| 4. Is the descriptor complete before the hot path receives it? | Yes | `TilingStrategy.init` compiles the closed value; projection and renderer only read it. |
| 5. Are geometry and dedup driven by compiled data? | Yes | The kernel reads basis/phase/reflections/images; projection reads `coincidentImagePolicy`. |
| 6. Does Metal dispatch on family plus unchanged preset wire? | Yes | Frame uniforms carry compiled family at offset 52 and preset wire at offset 40. |
| 7. Is the independent oracle descriptor-free? | Yes | Source guard and phase implementation-range diff are empty for all forbidden descriptor names. |
| 8. Are canonical raster bytes and metadata-switch semantics unchanged? | Yes | All 123 PNGs are byte-identical and the metadata-switch positive/negative pair behaves as designed. |
| 9. Do macOS and iPad targets build? | Yes | Both required Xcode commands report `BUILD SUCCEEDED`. |
| 10. Did this phase avoid square, triangular, radial, per-layer, and export scope? | Yes | The production diff adds only the rectangular foundation and dispatch seam; no new controls, modes, ownership domains, or export path were added. |

All ten answers are “Yes”; no completion blocker remains.

## Remaining Delivery Phases

These are planned later capabilities, not Phase 1 defects:

- **Phase 2:** square `p4`/`p4m` families, ownership domains, exports, and UI
  presets;
- **Phase 3:** triangular lattice, `p3`, `p6`, `p3m1`, `p6m`, and rectangular
  supercell export;
- **Phase 4:** finite/radial documents, `C_n`/`D_n`, geometry locking, and
  canonical sector storage;
- **Phase 5:** persistence migration, the expanded export matrix, performance
  and memory evidence, and final product acceptance.

Per-layer symmetry remains deferred by the governing design. Phase 1 makes no
claim for physical-device timing or later-family product acceptance.
