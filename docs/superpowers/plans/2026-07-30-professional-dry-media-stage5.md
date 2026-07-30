# Stage 5 Professional Dry-Media Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship four authored, deterministic professional dry/non-interacting
brush families—Technical Ink, Graphite Pencil, Natural Charcoal, and Chisel
Marker—on the Stage 4 deposition backend, adopt them in the editor, and prove
their software behavior with a clean Stage 5 gate.

**Architecture:** Preserve the exact Stage 4 diagnostic catalog, semantic
hashes, texture bytes, and gate. Add a separate professional catalog backed by
larger deterministic built-in tip/grain assets, a platform-free calibration
corpus, and family-specific native `BrushDefinition`s. The editor consumes a
small composed catalog that migrates old selections without changing Stage 4
source truth. Stage 5 extends the existing characterization, Metal harness,
manual-card, and artifact-validation paths instead of introducing a second
renderer.

**Tech Stack:** Swift 6 with complete concurrency checking, Swift Testing,
Metal/MetalKit, SwiftUI/AppKit/UIKit, JSON evidence, Bash, XcodeGen 2.46+,
macOS 14+, iPadOS 18+.

**Approved design:**
`docs/superpowers/specs/2026-07-30-professional-dry-media-stage5-design.md`

**Implementation status:** All six slices and all software tasks are
complete. The clean Stage 5 gate reaches its designed exit `2`,
`BRUSH STAGE 5 MANUAL/PHYSICAL PENDING`. Product acceptance remains pending
only for the 68 user-owned perceptual assessments and eight physical-device
profiles listed in the milestone.

## Global Constraints

- Execute directly on `main`; the user explicitly requested the existing main
  checkout.
- Never stage the pre-existing untracked `.vscode/` directory.
- Complete tasks in order. A later family may reuse reviewed helpers from an
  earlier task, but it may not retune an earlier family silently.
- Follow red-green-refactor. Every test must name an observable break and
  exercise real production behavior.
- Run focused tests while iterating, `git diff --check` before every commit,
  and the full Swift suite once per implementation task before committing.
- Keep `StageFourAnchorDefinitions`, `AnchorBrushCatalog`, their semantic
  hashes, their 64×64 texture bytes, and `verify-brush-stage4.sh` behavior
  unchanged.
- `PatternEngine` imports no Metal, MetalKit, UIKit, AppKit, or SwiftUI.
- Professional brushes use the existing native `BrushDefinition` →
  `BrushProgram` → `CompiledBrush` → deposition path. Do not add a parallel
  renderer or compatibility recipe path.
- Professional built-in assets are deterministic CPU-generated source bytes
  with deterministic CPU mipmaps. No file I/O, image decode, GPU mip
  generation, wall clock, platform RNG, or device-dependent generation.
- Old identities retain a 64-pixel source dimension and exact resource byte
  counts. New tip identities use 128; new grain identities use 256.
- All professional definitions declare `.realtime120`, use `.perStroke`
  seeding, interaction `.none`, and the exact authored values in the design.
- Definitions reference professional assets as optional resources with
  explicit matching built-in fallbacks. Required resources never silently
  fall back.
- Any `Dictionary` or `Set` traversal affecting hashes, serialization,
  compilation, resource order, evidence order, or pixels is explicitly
  sorted.
- Dynamics and random decisions are evaluated once in world space before
  symmetry projection. Full shape and grain frames transform with rotated and
  reflected copies.
- Actual/coalesced input alone determines committed pixels; prediction remains
  replaceable and lower priority.
- No brush requests wet interaction, pickup, reservoir, smudge, or soften
  work. Wet media belongs to Stage 6.
- The Stage 4 eraser must erase each professional family through the existing
  destination-out path.
- Automated checks may prove deterministic, functional, seam, radial,
  resource, memory, and performance contracts. They must never self-pass
  perceptual quality.
- Metal tests skip only when `MTLCreateSystemDefaultDevice()` is `nil`.
  Paravirtual/simulator results cannot satisfy physical performance.
- Correctness never becomes pending. Exit `2` is only the all-software-green
  state with manual and/or physical evidence unavailable or unset.
- Each task commits only its own files and records RED/GREEN evidence in its
  report.

## Slice And Task Map

| Stage 5 slice | Plan tasks |
| --- | --- |
| 1. Calibration and asset foundation | 1–2 |
| 2. Technical Ink | 3 |
| 3. Graphite Pencil | 4 |
| 4. Natural Charcoal | 5 |
| 5. Chisel Marker and editor adoption | 6–7 |
| 6. Cross-family evidence and acceptance | 8 |

---

### Task 1: Add The Professional Calibration Corpus And Logical Record

**Files:**

- Modify:
  `Sources/PatternEngine/Verification/StrokeTraceFixtures.swift`
- Create:
  `Sources/PatternEngine/Verification/ProfessionalBrushCharacterization.swift`
- Create:
  `Tests/PatternEngineTests/ProfessionalStrokeTraceTests.swift`
- Create:
  `Tests/PatternEngineTests/ProfessionalBrushCharacterizationTests.swift`

**Interfaces:**

- Add the ten exact `professional-*` normalized trace fixtures from the
  approved design and expose them through a stable ordered collection.
- Add `ProfessionalBrushCharacterizationRecord`,
  `ProfessionalBrushLogicalBaseline`, and
  `ProfessionalBrushCharacterizer`.
- Records use schema version `1`, sort by `(brushID, traceName)`, and contain
  the exact logical-dab metrics listed in design §8.
- Characterization uses nominal diameter `40`, black color, seed
  `0x5A17_E5`, and a 512×512 viewport centered at `(256, 256)`.
- Reject unsorted records, duplicate keys, nonfinite metrics, malformed
  bounds, and unsupported schemas with typed errors.

**Steps:**

- [x] Write tests that independently verify trace lifecycle, ordering,
  capability-bearing values, record sorting, duplicate/nonfinite rejection,
  deterministic encoding, and prediction replacement.
- [x] Run the focused tests and record the expected RED failures.
- [x] Implement the smallest platform-free corpus and characterization model.
- [x] Run:
  `swift test --disable-sandbox --no-parallel --filter
  'Professional(StrokeTrace|BrushCharacterization)Tests'`.
- [x] Run `swift test --disable-sandbox --no-parallel`.
- [x] Run `git diff --check`.
- [x] Commit as `feat(brush): add Stage 5 calibration corpus`.

---

### Task 2: Add Deterministic Professional Tip And Grain Assets

**Files:**

- Modify:
  `Sources/MetalRenderer/Brush/BrushTextureFactory.swift`
- Modify:
  `Sources/MetalRenderer/BrushCompiler/BrushCompiler.swift`
- Modify, if dimension ownership requires it:
  `Sources/MetalRenderer/Brush/BrushResourceResolver.swift`
- Modify:
  `Tests/MetalRendererTests/BrushTextureTests.swift`
- Modify:
  `Tests/MetalRendererTests/BrushCompilerTests.swift`

**Interfaces:**

- Extend `BrushTextureIdentity` with:
  `technicalNibShape`, `graphiteTipShape`, `charcoalTipShape`,
  `markerChiselShape`, `graphiteGrain`, and `charcoalGrain`, using the exact
  raw IDs in design §6.
- Give each identity an explicit `sourceDimension`; old identities remain 64,
  new tips are 128, and new grains are 256.
- Make CPU pyramid construction, Metal texture creation, resolver fallback,
  and compiler residency accounting use each identity's source dimension.
- Preserve every old base-level byte, mip level, mip count, Stage 4 resident
  byte count, and semantic hash.
- Generate each professional base level deterministically with visibly
  distinct authored characteristics and valid grayscale coverage.

**Steps:**

- [x] Write tests that fail if any old texture changes, any new dimension or
  mip count is wrong, generation differs between runs, a professional texture
  is blank/uniform, identities are confused, or compiler byte accounting is
  not dimension-aware.
- [x] Run the focused tests and record RED.
- [x] Implement dimension ownership and the six deterministic generators.
- [x] Run:
  `swift test --disable-sandbox --no-parallel --filter
  'Brush(Texture|Compiler)Tests'`.
- [x] Run `swift test --disable-sandbox --no-parallel`.
- [x] Run `git diff --check`.
- [x] Commit as `feat(brush): add professional texture pack`.

---

### Task 3: Implement Technical Ink

**Files:**

- Create:
  `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift`
- Create:
  `Sources/EditorCore/Brushes/ProfessionalBrushCatalog.swift`
- Create:
  `Tests/EditorCoreTests/ProfessionalBrushCatalogTests.swift`
- Create:
  `Tests/EditorCoreTests/ProfessionalBrushDynamicsTests.swift`
- Modify, if necessary for public characterization:
  `Sources/PatternEngine/Verification/ProfessionalBrushCharacterization.swift`

**Interfaces:**

- Add `ProfessionalBrushCatalog.technicalInk` with stable ID
  `builtin.professional-technical-ink`, display name `Technical Ink`, and the
  exact definition in design §7.1.
- Declare the technical-nib shape as an optional resource with its exact
  built-in fallback.
- Keep catalog order stable even while the remaining family entries are added
  in later tasks.
- Characterization must prove pressure size/flow response, zero scatter,
  direction-following rotation, finite mouse fallback, no interaction, and
  deterministic replay.

**Steps:**

- [x] Write catalog/definition and end-to-end logical-dab behavior tests;
  avoid assertions that only repeat stored constants.
- [x] Run the focused tests and record RED.
- [x] Implement Technical Ink and only shared definition helpers whose second
  use is already required by this plan.
- [x] Run:
  `swift test --disable-sandbox --no-parallel --filter
  'ProfessionalBrush(Catalog|Dynamics)Tests'`.
- [x] Run `swift test --disable-sandbox --no-parallel`.
- [x] Run `git diff --check`.
- [x] Commit as `feat(brush): add professional technical ink`.

---

### Task 4: Implement Graphite Pencil

**Files:**

- Modify:
  `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift`
- Modify:
  `Sources/EditorCore/Brushes/ProfessionalBrushCatalog.swift`
- Modify:
  `Tests/EditorCoreTests/ProfessionalBrushCatalogTests.swift`
- Modify:
  `Tests/EditorCoreTests/ProfessionalBrushDynamicsTests.swift`

**Interfaces:**

- Add `ProfessionalBrushCatalog.graphitePencil` with stable ID
  `builtin.professional-graphite-pencil`, display name `Graphite Pencil`, and
  the exact definition in design §7.2.
- Bind graphite grain in brush-local coordinates and Stage 4 paper grain in
  canonical coordinates; declare `dualGrain`.
- Characterization proves pressure size/flow/opacity response, tilt
  hardness/grain response, deterministic bounded variation, dry breakup,
  useful mouse fallback, and no interaction.

**Steps:**

- [x] Add real logical-dab tests that distinguish light/heavy pressure,
  upright/tilted input, repeated seeds, mouse fallback, and a deliberately
  missing dual-grain declaration.
- [x] Run focused tests and record RED.
- [x] Implement Graphite Pencil.
- [x] Run:
  `swift test --disable-sandbox --no-parallel --filter
  'ProfessionalBrush(Catalog|Dynamics)Tests'`.
- [x] Run `swift test --disable-sandbox --no-parallel`.
- [x] Run `git diff --check`.
- [x] Commit as `feat(brush): add professional graphite pencil`.

---

### Task 5: Implement Natural Charcoal

**Files:**

- Modify:
  `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift`
- Modify:
  `Sources/EditorCore/Brushes/ProfessionalBrushCatalog.swift`
- Modify:
  `Tests/EditorCoreTests/ProfessionalBrushCatalogTests.swift`
- Modify:
  `Tests/EditorCoreTests/ProfessionalBrushDynamicsTests.swift`

**Interfaces:**

- Add `ProfessionalBrushCatalog.naturalCharcoal` with stable ID
  `builtin.professional-natural-charcoal`, display name `Natural Charcoal`,
  and the exact definition in design §7.3.
- Bind the charcoal tip plus multiplied soft-round envelope and bind
  brush-local charcoal plus canonical paper grains; declare `dualShape` and
  `dualGrain` with stable sorted identifiers.
- Characterization proves broader size and scatter spans plus a broader
  deterministic randomized grain-offset range than Graphite Pencil; §7.3
  tilt/pressure grain-scale endpoints remain exact. It also proves tilt
  broadening/softening, deterministic seeded variation, dry breakup, finite
  mouse fallback, and no interaction.

**Steps:**

- [x] Add real logical-dab and validation tests for the two-layer resources,
  comparative dynamic ranges, deterministic variation, and capability
  failures.
- [x] Run focused tests and record RED.
- [x] Implement Natural Charcoal.
- [x] Run:
  `swift test --disable-sandbox --no-parallel --filter
  'ProfessionalBrush(Catalog|Dynamics)Tests'`.
- [x] Run `swift test --disable-sandbox --no-parallel`.
- [x] Run `git diff --check`.
- [x] Commit as `feat(brush): add professional natural charcoal`.

---

### Task 6: Implement Chisel Marker And Complete The Professional Catalog

**Files:**

- Modify:
  `Sources/EditorCore/Brushes/ProfessionalBrushDefinitions.swift`
- Modify:
  `Sources/EditorCore/Brushes/ProfessionalBrushCatalog.swift`
- Modify:
  `Tests/EditorCoreTests/ProfessionalBrushCatalogTests.swift`
- Modify:
  `Tests/EditorCoreTests/ProfessionalBrushDynamicsTests.swift`
- Modify:
  `Tests/EditorCoreTests/AnchorBrushCharacterizationTests.swift`

**Interfaces:**

- Add `ProfessionalBrushCatalog.chiselMarker` with stable ID
  `builtin.professional-chisel-marker`, display name `Chisel Marker`, and the
  exact definition in design §7.4.
- Finish the exact four-entry professional order.
- Characterization proves direction-following chisel rotation, zero scatter,
  bounded translucent buildup, the marker accumulation/edge family,
  deterministic replay, finite mouse fallback, and no interaction.
- Add one cross-family test that compiles all four definitions, requires four
  distinct semantic hashes, rejects wet settings, and characterizes all 40
  brush/trace combinations in stable order.

**Steps:**

- [x] Add marker and cross-family tests, run them, and record RED.
- [x] Implement Chisel Marker and the complete ordered catalog.
- [x] Run:
  `swift test --disable-sandbox --no-parallel --filter
  'ProfessionalBrush|AnchorBrushCharacterizationTests'`.
- [x] Run `swift test --disable-sandbox --no-parallel`.
- [x] Run `git diff --check`.
- [x] Commit as `feat(brush): add professional chisel marker`.

---

### Task 7: Adopt The Professional Catalog In The Editor And Brush Lab

**Files:**

- Create:
  `Sources/EditorCore/Brushes/EditorBrushCatalog.swift`
- Create:
  `Tests/EditorCoreTests/EditorBrushCatalogTests.swift`
- Modify:
  `App/PatternSpike/ContentView.swift`
- Modify:
  `App/PatternSpike/Panels/EditorTopBar.swift`
- Modify:
  `App/PatternSpike/EditorSessionController.swift`
- Modify:
  `App/PatternSpike/BrushLab/BrushLabManualCard.swift`
- Modify:
  `App/PatternSpike/BrushLab/BrushLabSession.swift`
- Modify focused app tests under:
  `App/Tests/`

**Interfaces:**

- `EditorBrushCatalog.drawEntries` returns the four professional entries
  followed by Native Glaze and Native Airbrush.
- `EditorBrushCatalog.defaultDraw` is Technical Ink;
  `EditorBrushCatalog.eraser` remains the Stage 4 eraser.
- `EditorBrushCatalog.resolveSelection(_:)` implements every migration in
  design §5.2 and rejects unknown IDs.
- App bootstrap, picker rendering, asynchronous compilation, latest-selection
  wins behavior, persisted selection restoration, tool switching, and
  compilation-failure rollback use the editor catalog without changing
  transaction semantics.
- Brush Lab exports the exact Stage 5 manual matrix for all four professional
  brushes. Every perceptual assessment starts unset and remains user-owned.
- Existing Stage 4 manual evidence remains available as Stage 4 evidence; it
  is not relabeled as professional.

**Steps:**

- [x] Add EditorCore migration/order tests and app integration tests for
  bootstrap, picker order, restored legacy IDs, rapid selection, failure
  rollback, draw/erase/draw, and professional manual-card generation.
- [x] Run focused tests and record RED.
- [x] Implement the composed editor catalog and migrate app consumers.
- [x] Run:
  `swift test --disable-sandbox --no-parallel --filter
  'EditorBrushCatalogTests|ContentViewLifecycleTests|EditorSessionControllerTests|BrushLabSessionTests'`.
- [x] Regenerate the Xcode project if source membership requires it:
  `xcodegen generate --spec App/project.yml`.
- [x] Build both app schemes for macOS and iPad Simulator.
- [x] Run `swift test --disable-sandbox --no-parallel`.
- [x] Run `git diff --check`.
- [x] Commit as `feat(app): adopt professional brush catalog`.

---

### Task 8: Add Stage 5 Metal Evidence, Artifact Validation, And Clean Gate

**Files:**

- Modify or extend:
  `Sources/MetalRenderer/Capture/DepositionHarnessRunner.swift`
- Create:
  `Sources/MetalRenderer/Capture/ProfessionalBrushEvidence.swift`
- Create:
  `Sources/MetalRenderer/Capture/ProfessionalBrushEvidenceValidator.swift`
- Create:
  `Sources/ProfessionalBrushEvidenceGate/main.swift`
- Modify:
  `Sources/BrushCharacterizationTool/main.swift`
- Modify:
  `Package.swift`
- Modify:
  `App/PatternSpike/Harness/HarnessLaunch.swift`
- Add eight Stage 5 scenes under:
  `App/PatternSpike/Harness/Scenes/`
- Create:
  `Tests/MetalRendererTests/ProfessionalBrushHarnessRunnerTests.swift`
- Create:
  `Tests/MetalRendererTests/ProfessionalBrushEvidenceValidatorTests.swift`
- Create:
  `scripts/verify-brush-stage5.sh`
- Create:
  `docs/superpowers/milestones/12-professional-dry-media.md`
- Modify the project README/status document that currently points to Stage 4.

**Interfaces:**

- Add one positive and one fail-closed negative scene for each professional
  family using the exact scene names in design §10.
- Positive artifacts contain live/committed/canonical PNGs, logical
  characterization JSON, benchmark JSON, resolved resources, stable IDs and
  semantic hashes, compiler/cache counters, preview/commit delta, and
  applicable seam/radial/eraser invariants.
- Negative scenes exit exactly `1`, write no stdout, and write one structured
  stderr line.
- The artifact-only validator accepts only an exact sorted file/schema set,
  recomputes source/artifact hashes, rejects raw pass strings, validates
  Stage 4 regression provenance, and reports pass/pending/fail without
  consulting live renderer state.
- `BrushCharacterizationTool` exports the stable 40-record logical baseline
  without overwriting the frozen Stage 4 baseline.
- `verify-brush-stage5.sh` enforces a clean committed source tree, permits only
  the known untracked `.vscode/`, invokes Stage 4 as a prerequisite, runs all
  tests serially, builds/analyzes macOS and iPad Simulator, executes all
  positive/negative scenes, exports logical/manual evidence, and invokes the
  artifact-only validator.
- Gate exits: `0` complete including supplied manual/physical evidence, `2`
  all software correct with manual/physical pending, `1` any software or
  supplied-evidence failure.
- The milestone records exact commands, toolchain and source provenance,
  software measurements, unavailable hardware/manual items, and no claim
  beyond the evidence.

**Steps:**

- [x] Write focused harness and artifact-validator tests first, including
  mutations for every required field, file, status, source hash, duplicate,
  order, negative-control, and raw-pass-string rejection.
- [x] Run focused tests and record RED.
- [x] Implement the Stage 5 evidence schema, scenes, runner support,
  characterization export, executable validator, and clean script.
- [x] Run:
  `swift test --disable-sandbox --no-parallel --filter
  'ProfessionalBrush(HarnessRunner|EvidenceValidator)Tests'`.
- [x] Run every positive and negative scene from a built macOS app.
- [x] Run `swift test --disable-sandbox --no-parallel`.
- [x] Regenerate the Xcode project and build/analyze macOS and iPad Simulator.
- [x] Commit all Task 8 source, tests, scenes, script, and milestone.
- [x] From that clean commit, run `scripts/verify-brush-stage5.sh`; accept only
  exit `0` or the designed exit `2`.
- [x] If the clean gate changes the milestone or checked-in status document,
  update it from measured evidence, commit that documentation-only delta, and
  rerun the clean gate.
- [x] Run `git diff --check`.
- [x] Commit implementation as
  `feat(gate): add Stage 5 professional brush evidence`.

---

## Whole-Stage Completion Review

- [x] Verify `git status --short` contains only the allowed untracked
  `.vscode/`.
- [x] Run `swift test --disable-sandbox --no-parallel`.
- [x] Run the Stage 4 clean gate and confirm its software result is unchanged.
- [x] Run `scripts/verify-brush-stage5.sh` from a clean commit and capture its
  exact exit and terminal status.
- [x] Run a fresh whole-range review from the pre-Stage-5 base through HEAD
  against the design and this plan.
- [x] Fix every Critical/Important correctness, security, maintainability, or
  plan-compliance finding with focused tests, then rerun the affected gates.
- [x] Confirm manual perceptual cards are pending rather than self-approved.
- [x] Report the four shipped brushes, editor migrations, deterministic and
  Metal evidence, software performance, and the exact remaining
  iPad/Pencil/Wacom/manual validation to the user.
