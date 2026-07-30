# Stage 5 Evidence Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Stage 5 clean gate derive every acceptance result from an
exact, self-contained artifact bundle while revalidating the frozen Stage 4
bundle and keeping absent human/physical evidence pending.

**Architecture:** Extract the frozen Stage 4 validator into a reusable
Metal-free library without changing its rules. Add a responsibility-split
`ProfessionalBrushEvidenceValidation` library for exact filesystem, scene,
renderer-observation, manual, physical, provenance, and orchestration checks;
the gate executable depends only on these artifact validators. The Metal
renderer remains the producer and writes the raw raster observations that the
artifact validator independently decodes and compares.

**Tech Stack:** Swift 6, Swift Testing, Foundation, CryptoKit, CoreGraphics,
ImageIO, SwiftPM, Metal test harness, Bash, `nm`, and `otool`.

## Global Constraints

- Do not weaken Stage 4, performance thresholds, or any existing evidence
  rule.
- Do not turn missing, malformed, unknown, or misspelled supplied evidence
  into pending; only complete absence may be pending.
- Producer booleans are diagnostics only and never establish an invariant.
- The professional gate binary must not link Metal, MetalKit, renderer code,
  or device-creation symbols.
- Keep user-owned `.vscode/` untouched and unstaged.
- Run one clean Stage 5 gate attempt only after direct verification is green.

---

### Task 1: Capture Fail-Closed RED Tests

**Files:**
- Modify: `Tests/MetalRendererTests/ProfessionalBrushHarnessRunnerTests.swift`
- Modify: `Tests/MetalRendererTests/ProfessionalBrushEvidenceValidatorTests.swift`
- Modify: `Tests/MetalRendererTests/DepositionEvidenceGateTests.swift`
- Modify: `App/Tests/BrushLabSessionTests.swift`

**Interfaces:**
- Consumes: current producer evidence, current artifact validator, current
  Stage 4 synthetic fixture, and the shipped professional manual catalog.
- Produces: focused mutation tests that fail against the reviewed code.

- [ ] **Step 1: Add scene and observation REDs**

Add tests that require filename/name binding, require the negative pair to
flip only `professionalDefinitionIdentityExact`, mutate every raw observation
pair/count/digest, and prove setting all diagnostic booleans to true cannot
repair a corrupted raster.

- [ ] **Step 2: Add root/schema/provenance REDs**

Add a reusable complete Stage 5 artifact fixture around
`StageFourArtifactFixture`. Mutate hidden entries, every root file, scene
input, Stage 4 artifact, executable cross-link, benchmark nested field,
characterization nested field, raw provenance file, and manifest entry.

- [ ] **Step 3: Add manual and physical REDs**

Use the shipped 68-card export as the valid manual fixture, then mutate order,
ID, brush, gesture, every nested key, assessment ID/value, unknown key, and
unknown supplied entry. Reuse the Stage 4 physical schema fixture, then mutate
profile identity, exact metric order/unit/threshold/sample/device fields and
an unknown GPU identity.

- [ ] **Step 4: Run focused RED**

Run:

```bash
swift test --disable-sandbox --no-parallel \
  --filter 'ProfessionalBrush(HarnessRunner|EvidenceValidator)Tests|professionalManualArtifact'
```

Expected: fail because the artifact validator accepts one or more mutations
and the new observation/schema APIs do not exist.

---

### Task 2: Extract Frozen Stage 4 Validation

**Files:**
- Create: `Sources/BrushDepositionEvidenceValidation/StageFourEvidenceValidator.swift`
- Modify: `Sources/BrushDepositionEvidenceGate/main.swift`
- Modify: `Package.swift`
- Modify: `Tests/MetalRendererTests/DepositionEvidenceGateTests.swift`

**Interfaces:**
- Produces:
  `StageFourEvidenceValidator.validate(artifactRoot:expectedCommit:expectedSourceTreeSHA256:)`.
- Preserves every existing Stage 4 constant, schema, threshold, physical
  profile rule, manifest rule, and status result byte-for-byte in behavior.

- [ ] **Step 1: Move validator types and logic**

Move all declarations before the Stage 4 `@main` entry point into the new
library target; leave the CLI parser and terminal mapping in the executable.

- [ ] **Step 2: Rewire dependencies**

Make `BrushDepositionEvidenceGate` depend on
`BrushDepositionEvidenceValidation`, and make tests import the library.

- [ ] **Step 3: Verify frozen behavior**

Run:

```bash
swift test --disable-sandbox --no-parallel \
  --filter 'DepositionEvidenceGateTests'
```

Expected: all existing Stage 4 validator tests pass unchanged.

---

### Task 3: Emit Artifact-Derived Renderer Observations

**Files:**
- Modify: `Sources/MetalRenderer/Capture/ProfessionalBrushEvidence.swift`
- Modify: `Sources/MetalRenderer/Capture/DepositionHarnessRunner.swift`
- Modify: `Tests/MetalRendererTests/ProfessionalBrushHarnessRunnerTests.swift`

**Interfaces:**
- Produces: exact raw PNG pairs for prediction off/on, grid
  origin/translated, eraser before/after, radial rotation
  rendered/reference, and radial reflection rendered/reference.
- Produces: evidence measurements for raw BGRA digests, nontransparent pixel
  counts, maximum deltas, replay limits, compiler counters, resource counts,
  telemetry bounds, and renderer executable SHA-256.

- [ ] **Step 1: Replace boolean-returning professional audits**

Return observation records containing the raw raster bytes and counts. Keep
the existing boolean dictionary only for immediate harness diagnostics and
negative expectation reporting.

- [ ] **Step 2: Build independent radial references**

Render a no-symmetry canonical trace. Construct the expected two-ray rotation
and one-ray reflection rasters by exact center transforms, render the matching
finite symmetry configurations, and write both rendered and reference PNGs.

- [ ] **Step 3: Write the expanded artifact set**

Write the ten observation PNGs atomically and include all observation
measurements plus the running executable digest in schema-v2 evidence.

- [ ] **Step 4: Run focused harness GREEN**

Run:

```bash
swift test --disable-sandbox --no-parallel \
  --filter ProfessionalBrushHarnessRunnerTests
```

Expected: four real-Metal positives write the exact expanded set, and four
negative controls fail only the definition expectation after all other
observations validate.

---

### Task 4: Build The Metal-Free Artifact Validator

**Files:**
- Create: `Sources/ProfessionalBrushEvidenceValidation/ArtifactFileSystem.swift`
- Create: `Sources/ProfessionalBrushEvidenceValidation/ProfessionalBrushTruth.swift`
- Create: `Sources/ProfessionalBrushEvidenceValidation/SceneArtifactValidator.swift`
- Create: `Sources/ProfessionalBrushEvidenceValidation/ManualEvidenceValidator.swift`
- Create: `Sources/ProfessionalBrushEvidenceValidation/PhysicalEvidenceValidator.swift`
- Create: `Sources/ProfessionalBrushEvidenceValidation/ProvenanceValidator.swift`
- Create: `Sources/ProfessionalBrushEvidenceValidation/ProfessionalBrushArtifactValidator.swift`
- Delete: `Sources/MetalRenderer/Capture/ProfessionalBrushEvidenceValidator.swift`
- Modify: `Sources/ProfessionalBrushEvidenceGate/main.swift`
- Modify: `Package.swift`

**Interfaces:**
- Produces:
  `ProfessionalBrushArtifactValidator.validate(artifactRoot:expectedCommit:expectedSourceTreeSHA256:expectedStageFourArtifactRoot:)`.
- Consumes the frozen Stage 4 validator and its actual bundle.

- [ ] **Step 1: Implement exact filesystem and JSON primitives**

Enumerate without `.skipsHiddenFiles`, reject symlinks and every unexpected
file/directory, parse integers without Boolean bridging, reject unknown keys
at every nested level, and recompute the recursively exact manifest.

- [ ] **Step 2: Derive every renderer invariant**

Decode every PNG to normalized BGRA8, recompute digests/counts/deltas, compare
each observation pair, verify radial rendered/reference pixels, derive
eraser alpha reduction, and derive bounded work/resources/counters/telemetry.
Ignore producer diagnostic booleans for acceptance.

- [ ] **Step 3: Strictly validate benchmark and characterization**

Require the exact schema-v3 benchmark key set and nested build/hardware keys;
cross-check configuration, commit, GPU, OS, fixed seed `0x4c415941`,
`canonicalBGRA8Digest`, `newInstanceCounts`, counts, byte ranges, missed-frame
and replay bounds. Require exact characterization keys, exact 40-record
baseline identity/order, and renderer-record membership.

- [ ] **Step 4: Revalidate Stage 4**

Invoke the extracted `StageFourEvidenceValidator` on the actual bundle, then
recompute its recursive manifest and cross-links. Compare any recorded exit or
terminal fields only to the freshly derived result; never use text as proof.

- [ ] **Step 5: Validate manual and physical evidence**

Bind the exact shipped 68-card catalog and nested schema. Allow only explicit
assessment enumerations plus bounded notes; all-null is pending, exact complete
values pass, and partial/unknown/misspelled input fails. Require Stage 5
physical profiles to be the exact eight Stage 4 schema-v2 profiles already
validated by the frozen validator, byte-bind them to that bundle, and add a
positive known-hardware GPU identity check.

- [ ] **Step 6: Verify focused artifact GREEN**

Run:

```bash
swift test --disable-sandbox --no-parallel \
  --filter ProfessionalBrushEvidenceValidatorTests
```

Expected: the complete synthetic root passes/pends as designed and every
mutation fails closed.

---

### Task 5: Make The Clean Script Exact And Reachable

**Files:**
- Modify: `scripts/verify-brush-stage5.sh`
- Modify: `Tests/MetalRendererTests/ProfessionalBrushEvidenceValidatorTests.swift`

**Interfaces:**
- Consumes:
  `PROFESSIONAL_BRUSH_MANUAL_EVIDENCE_FILE` and
  `PROFESSIONAL_BRUSH_PHYSICAL_EVIDENCE_DIR`.
- Produces: pending only when an input is absent; malformed or unknown supplied
  entries fail before artifact validation.

- [ ] **Step 1: Add strict optional manual input**

Generate the shipped pending catalog when the variable is unset. When set,
require a regular non-symlink file and copy it unchanged as `catalog.json`;
the artifact validator decides complete versus invalid.

- [ ] **Step 2: Reject unknown supplied entries**

Enumerate all manual/physical source entries without hidden filtering and
reject anything outside the exact allowlist before copying.

- [ ] **Step 3: Bundle raw provenance and executable**

Copy the built app executable and raw toolchain/hardware outputs into the
artifact root, hash each in provenance, normalize JSON values from those raw
files, and bind every scene to the executable SHA-256.

- [ ] **Step 4: Enforce the binary boundary**

Capture `otool -L` and `nm -u` output for the gate executable. Fail if Metal,
MetalKit, `MTLCreateSystemDefaultDevice`, renderer modules, or renderer symbols
appear; include the audit files in the manifest.

- [ ] **Step 5: Run shell behavioral tests**

Run:

```bash
bash -n scripts/verify-brush-stage5.sh
swift test --disable-sandbox --no-parallel \
  --filter ProfessionalBrushEvidenceValidatorTests
```

Expected: absent inputs continue pending, supplied unknown entries exit `1`,
and valid supplied manual data can make manual evidence complete.

---

### Task 6: Direct Verification, Commit, And One Clean Gate

**Files:**
- Modify: `.superpowers/sdd/2026-07-30-professional-dry-media-stage5/task-8-report.md`

**Interfaces:**
- Produces: committed review fix and an evidence-based completion or
  environmental-blocker report.

- [ ] **Step 1: Run focused tests and every scene/export**

Run the focused validator/harness selection, all four positive scenes, all
four paired negatives, the 40-record characterization export, the 68-card
manual export, and the binary-boundary audit.

- [ ] **Step 2: Run whole-repository verification**

Run:

```bash
swift test --disable-sandbox --no-parallel
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac \
  -configuration Debug -destination platform=macOS build
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac \
  -configuration Debug -destination platform=macOS analyze
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad \
  -configuration Debug -destination 'generic/platform=iOS Simulator' build
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad \
  -configuration Debug -destination 'generic/platform=iOS Simulator' analyze
git diff --check
```

- [ ] **Step 3: Commit coherent fixes**

Stage only Task 8 source/tests/script/docs, excluding `.vscode/`, and create a
Conventional Commit describing the fail-closed evidence repair.

- [ ] **Step 4: Attempt one clean gate**

Run `./scripts/verify-brush-stage5.sh` once from the clean commit. Accept only
exit `0` or `2`; if the host GPU remains degraded, preserve the failure logs
and report the environmental blocker without retrying or changing policy.

- [ ] **Step 5: Append the Task 8 report**

Record the RED failures, architecture split, exact commands/counts, scene and
export results, binary audit, commit, clean result, and any remaining
manual/physical/environmental work.
