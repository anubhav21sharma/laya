# Authored Procreate Charcoal Corpus Implementation Plan

**Execution status (2026-08-12):** Tasks 1 through 7 and their automated
functional/performance evidence are complete. The approved archive remains on
the offline tooling path, the `.key` file remains excluded, and product manual
acceptance remains pending with the main corrective program.

**Goal:** Convert the replacement author-supplied `FREE Charcoal Set` into an
honestly reported native composite charcoal brush, with `C Charcoal` as the
primary target and `C Charcoal Soft` as a secondary characterization target.

**Architecture:** Extend the bounded offline converter to retain typed active
parent/sub-brush components. Add a format-neutral native composite dry-brush
model instead of pretending a full sub-brush is merely a second shape or grain
inside one dab. Replace absent Procreate built-ins with explicitly documented
Laya-owned resources derived from the supplied paper sources. The product
consumes only native packages and precompiled native resources.

**Tech stack:** Swift 6.0, Swift Testing, `BrushConverter`, `BrushFormat`,
`PatternEngine`, `MetalRenderer`, `SafeArchive`, ImageIO/CoreGraphics, Metal
harnesses, and `layabrush-convert`.

## Global Constraints

- Execute directly on `main`; do not create a worktree.
- Preserve unrelated user files, especially `.vscode/`.
- Source archive:
  `brushes/procreate/1_FREE_Charcoal_Set.brushset`.
- Source SHA-256:
  `efa2a655620844fc3cc0b2c26f81bf28f31d7b9e74677c31933c352cf13156cf`.
- Primary target:
  `CC70504F-0D16-4D26-88A6-BF47BDA8ADE8` (`C Charcoal`).
- Secondary target:
  `21AF8C6B-3FB1-4BF8-8F89-F5768271DA35` (`C Charcoal Soft`).
- Both targets have one active `Sub01` and `dualBlendMode = 1`.
- Active missing resources are `Haggard-Oval.png`,
  `Brush-Preset-Bonobo.png`, and `Brush-Artery-Charcoal-Corse.jpg`.
- Never use `NSKeyedUnarchiver` on foreign bytes; use bounded plist readers.
- Never fetch, package, or label a Procreate Source Library asset as owned.
- Never treat `Reset/**` as an active brush component.
- Never flatten independent component size, spacing, flow, or dynamics into
  ordinary dual shape/grain layers without equivalence evidence.
- Every observed rendering field is exact, resource-resampled, approximated,
  unsupported, or inactive-with-evidence; no silent defaults.
- Parser, conversion, normalization, decode, mip construction, upload, and
  pipeline creation never run on the pointer-input or frame path.
- Manual validation happens after all corrective stages and the full automated
  performance round; pending manual status does not block implementation but
  does block product acceptance.
- Physical iPad/Pencil and Wacom evidence remains pending.

## Pinned Corpus Inventory

The manifest order is:

1. `C3A956C4-00DB-4CA9-B5A2-6F0199B591EC` — Procreate Pencil - Remake
2. `0DADE934-8FD1-4680-AA5E-66D699CF21A0` — COFE Pencil - F
3. `21AF8C6B-3FB1-4BF8-8F89-F5768271DA35` — C Charcoal Soft
4. `CC70504F-0D16-4D26-88A6-BF47BDA8ADE8` — C Charcoal
5. `89185C2C-2746-4934-A9DB-20983D28BEED` — Finger Smudge
6. `ACF77570-AD91-4352-86C7-2C48BF0D7108` — Eraser - Soft
7. `77E04E60-98F7-4849-90E9-3F23C5B303DB` — Eraser - Medium
8. `C430FF39-0164-4E0B-A7E6-B6200BB89F86` — Eraser - Hard

Companion sources:

- `DSC_0006.jpg` —
  `5ce41606b51036394f841f519b7af45e9316012145d48acbe76cc7a5e43d309f`.
- `DSC_0175.jpg` —
  `929f5c3b301bfcee2acd0367b0147af4c27bc775547f50a347d3dc8c24a172d0`.
- `1_FREE_Charcoal_Set.key` is opaque and outside this plan.

## Planned Files

- `brushes/procreate/corpus.json`
- `brushes/procreate/substitutions.json`
- `brushes/procreate/README.md`
- `Sources/BrushConverter/ProcreateArchiveValueDecoder.swift`
- `Sources/BrushConverter/ForeignBrushComponent.swift`
- `Sources/BrushConverter/ProcreateBrushParser.swift`
- `Sources/BrushConverter/ProcreateBrushSemanticKeys.swift`
- `Sources/BrushConverter/ProcreateResourceSubstitution.swift`
- `Sources/BrushConverter/ProcreateClassicV1BrushMapper.swift`
- `Sources/PatternEngine/BrushModel/BrushComponentDefinition.swift`
- `Sources/PatternEngine/BrushModel/BrushDefinition.swift`
- `Sources/PatternEngine/CompositeBrushStrokeGenerator.swift`
- `Sources/MetalRenderer/BrushCompiler/CompiledBrush.swift`
- `Sources/MetalRenderer/Deposition/DepositionEncoder.swift`
- `Sources/BrushFormat/Resources/Professional/Charcoal/`
- `Tests/BrushConverterIntegrationTests/ProcreateCharcoalCorpusTests.swift`
- focused converter, engine, renderer, and app tests described below

---

## Task 1: Pin The Replacement Corpus And Boundary

**Files:**

- Create `brushes/procreate/corpus.json`.
- Create `brushes/procreate/README.md`.
- Create
  `Tests/BrushConverterIntegrationTests/ProcreateCharcoalCorpusTests.swift`.

- [x] Add a real-corpus test that independently computes the three file hashes,
  decodes `brushset.plist`, and verifies set name plus exact eight-member order.
- [x] Parse the archive through `ProcreateBrushParser` and verify all eight
  top-level identities/names are present. Do not depend on parser output order;
  compare a safely constructed keyed inventory and fail on duplicates.
- [x] Verify the current baseline explicitly: all eight inspect without crash,
  both target brushes report an active unsupported sub-brush, and the three
  required built-in resource names are absent from archive members.
- [x] Record archive/photo ownership, hashes, member inventory, target IDs,
  component topology, missing built-ins, and `notBundledInRelease: true` in
  `corpus.json`.
- [x] Document that replacement requires a new manifest revision and test hash;
  do not silently edit an accepted hash.
- [x] Explicitly exclude the `.key` file from parsing, fixtures, packaging, and
  release targets.
- [x] Run:

  ```bash
  swift test --filter ProcreateCharcoalCorpusTests
  .build/debug/layabrush-convert probe --json \
    brushes/procreate/1_FREE_Charcoal_Set.brushset
  .build/debug/layabrush-convert inspect --json \
    brushes/procreate/1_FREE_Charcoal_Set.brushset
  ```

  Expected: exact hashes/inventory pass; probe and inspect exit zero.

---

## Task 2: Retain Typed Values Per Component

**Files:**

- Create `Sources/BrushConverter/ProcreateArchiveValueDecoder.swift`.
- Modify `Sources/BrushConverter/ProcreateBrushParser.swift`.
- Modify `Sources/BrushConverter/ProcreateBrushSemanticKeys.swift`.
- Modify parser fixtures/tests and the real-corpus integration test.

- [x] Replace `.token("present")` for direct scalar values with bounded typed
  decoding of Boolean, integer, finite real, string, and null.
- [x] Keep unknown direct scalars in a stable raw namespace. Keep uncharacterized
  object graphs presence-only with a diagnostic; never copy them into runtime
  definitions.
- [x] Add stable semantic keys for the verified shape, grain, placement,
  dynamics, color, taper, material, and `dualBlendMode` fields.
- [x] Decode each active archive independently. Do not allow parent values to
  fill absent sub-brush fields implicitly.
- [x] Characterize and pin at least the following target evidence:
  parent/sub `paintSize`, `plotSpacing`, pressure size/opacity, tilt size/shape
  roundness, texture scale/movement, bundled shape/grain paths, and parent
  `dualBlendMode`.
- [x] Add malformed kind, non-finite, invalid UID, cycle, and aggregate-budget
  tests. The same hostile value must fail identically in root and sub-brush.
- [x] Run parser, archive, converter, and fuzz suites.

---

## Task 3: Parse Active Sub-Brushes Into Versioned Foreign IR

**Files:**

- Create `Sources/BrushConverter/ForeignBrushComponent.swift`.
- Modify `Sources/BrushConverter/ForeignBrushIR.swift`.
- Modify `Sources/BrushConverter/ProcreateBrushParser.swift`.
- Modify `Sources/BrushConverter/ForeignBrushDocument.swift` as required.
- Add focused component/parser/codec/fuzz tests.

**Representation:**

```swift
public struct ForeignBrushComponent: Codable, Equatable, Sendable {
    public let identifier: String       // "root", "sub01"
    public let ordinal: UInt16          // 0, 1
    public let sourcePath: String
    public let settings: [ForeignBrushSetting]
    public let resources: [ForeignBrushResourceDescriptor]
    public let diagnostics: [ForeignBrushDiagnostic]
}
```

- [x] Advance `ForeignBrushIR` to schema version 2 with ordered `components` as
  the single source of component settings/resources. Decode version 1 as one
  synthesized `root` component so existing fixtures/packages remain readable;
  encode new output only as version 2.
- [x] Parse only active root and `SubNN` paths. Ignore all `Reset/**`, QuickLook,
  Signature, and AuthorPicture paths for component discovery.
- [x] Support root plus `Sub01` in parser version 2. Represent the ordered array
  so later versions can raise the limit without redesigning IR.
- [x] Enforce depth one, maximum two active components, aggregate byte/pixel/
  object/setting/diagnostic budgets, normalized ZIP paths, and deterministic
  numeric `SubNN` ordering.
- [x] Reject duplicate logical components, case/path aliases, missing archive,
  non-contiguous active indices, traversal, and conflicting members with typed
  errors. Never construct a dictionary that can trap on duplicates.
- [x] Add tests proving Reset copies do not change active component count or
  hashes. Add fixtures with nested `Sub01/Sub01`, `Sub02` without `Sub01`, and
  component-level ZIP bombs.
- [x] Update CLI inspect JSON to expose component identity and diagnostics while
  keeping old top-level summaries readable.
- [x] Verify both charcoal targets contain exactly `root` and `sub01`, with the
  expected missing tip/grain references and no Reset contamination.
- [x] Run focused tests, full converter tests, deterministic fuzz campaigns,
  and `swift test`.

---

## Task 4: Add A Native Composite Dry-Brush Model

**Why:** The current `coverage.shapes`/`coverage.grains` arrays layer resources
inside one dab. A Procreate sub-brush has independent size, spacing, flow,
dynamics, and randomization. Treating it as a second texture would silently
discard behavior.

**Files:**

- Create `Sources/PatternEngine/BrushModel/BrushComponentDefinition.swift`.
- Modify `Sources/PatternEngine/BrushModel/BrushDefinition.swift`.
- Modify `Sources/PatternEngine/BrushModel/BrushProgram.swift`.
- Create `Sources/PatternEngine/CompositeBrushStrokeGenerator.swift`.
- Modify logical dab/batch models only as needed for stable component identity.
- Modify compiler, resource residency, deposition encoding, content hashing,
  package coding, and all affected tests.

- [x] Introduce native schema version 3 with one or two ordered dry components.
  Schema version 2 is already reserved by corrective-program Task 9 for ordered
  multi-sensor dynamics.
  Each component owns coverage, placement, dynamics, color, material, taper,
  and a stable identifier. Stroke-level metadata, stabilization, replay policy,
  limits, and seed policy remain shared.
- [x] Decode version-1 and version-2 `BrushDefinition` values as one canonical
  primary component, applying the existing v1-to-v2 dynamics adapter first.
  Migrate built-ins mechanically and prove byte/pixel compatibility through
  existing anchors before removing duplicated singular fields.
- [x] Define explicit bounded composition modes. Characterize Procreate
  `dualBlendMode = 1`; if exact equivalence cannot be established without an
  iPad, map the closest dry source-over composition as `approximated` and retain
  an acceptance flag. Unknown required modes block activation.
- [x] Drive all component generators from the same authoritative input samples
  while preserving independent resampling, dynamics, dabs, and random streams.
  Randomness is keyed by stroke seed, source identity, component ordinal,
  component-dab ordinal, and channel.
- [x] Preserve append-only causality. Component expansion is bounded by two,
  preallocated, and included in the frame-work budget. Never replay the stroke
  body to add the secondary component.
- [x] Carry stable component identity through compile and deposition so the
  renderer selects the correct textures/pipeline state. Batch/group only where
  doing so preserves declared composition order.
- [x] Apply tiling/radial transforms to the complete component dab transform;
  brush-local tip/grain orientation must rotate or reflect with each replica
  according to its coordinate mode.
- [x] Compute cursor support as the conservative evaluated union of visible
  components. Paint and erase must use identical component geometry.
- [x] Add one- and two-component definition validation, v1/v2 migration,
  deterministic digest, independent spacing, independent dynamics, component
  random isolation, symmetry, erase, history, empty-output, and budget tests.
- [x] Add a performance negative control whose component loop allocates or
  replays; the production path must reject/fail the intended gate.
- [x] Run `swift test` and the existing single-component raster anchors before
  accepting this schema migration.

---

## Task 5: Author And Admit Owned Charcoal Resources

**Files:**

- Create `Sources/BrushConverter/ProcreateResourceSubstitution.swift`.
- Create `brushes/procreate/substitutions.json`.
- Add source/derived assets and `PROVENANCE.md` under
  `Sources/BrushFormat/Resources/Professional/Charcoal/`.
- Add deterministic normalization tooling and resource-quality tests.

- [x] Implement an exact, case-sensitive, offline substitution registry with
  duplicate rejection, resource-role checks, byte count/hash verification,
  deterministic order, and no network/fuzzy lookup.
- [x] Author a Laya-owned irregular oval tip corresponding in physical role—not
  bytes—to `Haggard-Oval.png`. Preserve the editable lossless source and record
  every deterministic normalization operation.
- [x] Derive a fine paper-tooth grain and a coarse/fibrous charcoal grain from
  `DSC_0006.jpg` and/or `DSC_0175.jpg`. Correct EXIF orientation, crop,
  illumination, contrast, seams, and frequency balance offline.
- [x] Prefer separate outputs for the parent and sub-brush roles. Sharing one
  source is allowed only if parent-only/sub-only raster evidence proves that
  independent transforms provide genuinely distinct useful behavior.
- [x] Record source photo hash, crop/transform parameters, tool versions,
  derived hashes, intended role, color interpretation, support bounds, mip
  policy, maximum useful size, and license/ownership in `PROVENANCE.md`.
- [x] Map the three missing Procreate names to owned resource IDs with reason
  `project-owned-source-library-substitute`; never call them exact or
  resource-resampled.
- [x] Require dimensions/support, grayscale range, seam error, frequency bands,
  mip variance, no dominant line/repetition, and useful projected modulation.
- [x] Add blank, one-pixel, hard-seam, stripe, clipped-tip, and low-resolution
  negative controls.
- [x] Run resource, normalizer, cache/mip, and full tests.

---

## Task 6: Map Both Charcoal Targets To Native Packages

**Files:**

- Create `Sources/BrushConverter/ProcreateClassicV1BrushMapper.swift`.
- Modify semantic keys, command runner, conversion reports, and focused tests.

- [x] Map the root and `sub01` independently into two native components. Resolve
  all three missing resources only through the injected registry.
- [x] Preserve independent size, spacing, flow, opacity, pressure, tilt,
  rotation, scatter, grain transform, and randomization wherever the native
  contract has characterized equivalence.
- [x] Report every source field exactly once per component using a stable
  component-qualified key. Active unknown rendering controls are required-
  unsupported unless proven inert.
- [x] Keep both target packages dry: `interaction = .none`, append-only replay,
  causal termination, and no destination sampling. Wet/mix settings remain
  report data and cannot silently activate a backend.
- [x] Extend `convert` with explicit brush selection and substitution-manifest
  options. Reject duplicates, unknown IDs, unused replacements, role/hash/path
  mismatches, and missing required resources.
- [x] Keep `inspect` available for all eight brushes. `Finger Smudge` may prove
  embedded-resource normalization/package behavior, but conversion must remain
  inactive while smudge semantics are unsupported.
- [x] Convert each target twice:

  ```bash
  swift run layabrush-convert convert --json \
    --brush CC70504F-0D16-4D26-88A6-BF47BDA8ADE8 \
    --substitutions brushes/procreate/substitutions.json \
    --output .build/procreate-charcoal-run-1 \
    brushes/procreate/1_FREE_Charcoal_Set.brushset
  swift run layabrush-convert convert --json \
    --brush CC70504F-0D16-4D26-88A6-BF47BDA8ADE8 \
    --substitutions brushes/procreate/substitutions.json \
    --output .build/procreate-charcoal-run-2 \
    brushes/procreate/1_FREE_Charcoal_Set.brushset
  swift run layabrush-convert convert --json \
    --brush 21AF8C6B-3FB1-4BF8-8F89-F5768271DA35 \
    --substitutions brushes/procreate/substitutions.json \
    --output .build/procreate-charcoal-soft \
    brushes/procreate/1_FREE_Charcoal_Set.brushset
  ```

- [x] Require byte-identical repeated primary output, save/reopen equivalence,
  complete reports, and no parser/converter dependency in the packages.
- [x] Run focused mapper/CLI/integration/fuzz tests and `swift test`.

---

## Task 7: Rebuild Natural Charcoal And Gate It Functionally

**Depends on:** corrective program Stages B through E and Tasks 1–6 above.

**Files:**

- Modify `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift`.
- Admit final resources under the native Charcoal resource directory.
- Modify professional dynamics and Metal functional tests.
- Modify the Natural Charcoal harness scene and manual card.

- [x] Use the primary conversion as the baseline and the soft target as a
  cross-check. Any native retune must be recorded as an approximation in
  retained evidence; it cannot silently diverge from both targets.
- [x] Add parent-only, child-only, and combined characterization scenes. Each
  component must make a measurable useful contribution; disabling either must
  change its intended texture/coverage metric.
- [x] At low/neutral/high pressure check changed pixels, alpha percentiles,
  visible width versus evaluated support, broad-side/edge variation, and cursor
  agreement. Sparse pores may use documented percentile-aware tolerance, but
  a 40 px cursor cannot hide a hairline principal stroke.
- [x] Test straight, curve, tight turn, reversal, stationary hold, short tap,
  and pointer-up. Require continuity, no spikes/icicles, causal endpoint, and
  no retroactive body change.
- [x] Test repeated-pass buildup, local paper anchoring, scale/zoom behavior,
  periodic seams, radial rotation/reflection, erase parity, undo/redo, clear,
  deterministic replay, and predicted-input replacement.
- [x] Run all negative controls: blank/one-pixel/clipped tip, missing fine grain,
  missing coarse grain, disabled component, merged random streams, shrunken
  support, zero flow, hard seam, and retained-body replay.
- [x] Run nominal and large-size production-path performance traces in plain,
  periodic, and maximum radial symmetry. Persist HUD and JSONL counters for CPU
  preparation, input-to-submit, GPU time, FPS, missed frames, backlog, dabs by
  component, cache hits/misses, memory, uploads, pipeline creation, and replay.
- [x] Include Natural Charcoal in the full post-Stage-G performance matrix:
  cold selection, warm long strokes, size extremes, cache churn, memory
  pressure, 10-second traces, and accelerated 10-minute traces repeated three
  times. No decode/upload/pipeline creation/GPU wait/replay may occur on the
  warm input path.
- [x] Export deterministic PNG/JSON evidence and keep
  `manualQualityPassed = false` and `productAccepted = false` until the final
  user review.
- [x] Run focused suites, both Debug and Release macOS app builds, `swift test`,
  and the full corrective evidence gate.

---

## Completion Boundary

This focused plan is software-complete only when Tasks 1–7 and the full
post-Stage-G performance round pass. It remains manually unaccepted until the
user reviews the final brush behavior.

The remaining pencil/eraser presets are parser regression cases, not product
delivery promises. `Finger Smudge` resource parsing is in scope; smudge
behavior is deferred to the ordered destination-sampling backend.

## Self-Review Checklist

- [x] Replacement archive/photo hashes and all eight members match disk.
- [x] Root and active `Sub01` parse; Reset copies never become components.
- [x] All readers and component budgets remain bounded and fuzzed.
- [x] Native composite components preserve independent settings and randomness.
- [x] Single-component native brushes retain their established behavior.
- [x] No missing Procreate resource is copied or called exact.
- [x] Owned tip/grains carry reproducible provenance and quality evidence.
- [x] Every source field has one component-qualified report disposition.
- [x] Runtime/release targets contain no Procreate parser, archive, or key.
- [x] Cursor, paint, erase, tiling, radial transforms, and history agree.
- [x] Negative controls prove the gates can detect invisible, undersized,
  textureless, single-component, discontinuous, or replay-heavy output.
- [x] Warm performance evidence proves no decode/upload/pipeline/replay work.
- [x] Manual validation is deferred but remains mandatory for acceptance.
