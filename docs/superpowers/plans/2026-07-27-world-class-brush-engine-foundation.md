# World-Class Brush Engine Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Characterize the current brush output and build the versioned,
compiled, resource-aware foundation that subsequent Procreate conversion and
deposition-renderer plans can consume without changing current pixels.

**Architecture:** Preserve `BrushRecipe` as a temporary compatibility input
while introducing immutable `BrushDefinition`, pure `BrushProgram`, ordered
`LogicalDabBatch`, secure `.layabrush` packaging, and asynchronously prepared
Metal resources. Existing anchor brushes are adapted and compiled before
pointer-down; the current renderer remains the only drawing backend in this
plan.

**Tech Stack:** Swift 6.0 with complete concurrency checking, Swift Testing,
Metal/MetalKit, ImageIO/CoreGraphics, CryptoKit, XcodeGen 2.46+, macOS 14+,
iPadOS 18+.

## Global Constraints

- Execute directly on `main`; do not create a worktree.
- Before implementation, resolve or commit the pre-existing dirty changes.
  Never stage unrelated files with a task commit.
- iPadOS 18+ is the primary product target; macOS 14+ remains the development
  and Wacom target.
- `PatternEngine` imports no UIKit, AppKit, SwiftUI, Metal, or MetalKit.
- Canonical pixels, transaction ownership, history, tiling, symmetry, preview,
  and commit semantics remain unchanged.
- World-space path and dynamics evaluation remain before symmetry projection.
- Authoritative actual/coalesced samples, including their resolved estimated
  properties, alone determine committed output. Prediction stays replaceable
  and never advances authoritative state.
- Built-in anchors must remain pixel-identical through the compatibility path.
- File I/O, archive parsing, image decode, mip generation, and pipeline or
  texture preparation never run during input handling.
- The new BrushFormat/BrushCompiler path reports every resource failure
  explicitly. The legacy resolver remains only for exact built-in anchor IDs
  during migration and must never receive a packaged-resource ID.
- Source assets remain lossless in `.layabrush`; compiled GPU resources are
  disposable caches.
- No public Brush Studio, Procreate parser, new deposition backend, Wet Mix
  backend, tile shader, sparse texture, or final preset calibration belongs to
  this plan.
- Existing tests and the complete Slice 4 correctness matrix remain mandatory.
- Tests that require Metal may skip only when `MTLCreateSystemDefaultDevice()`
  returns `nil`; pure tests never skip.

---

## File And Ownership Map

### Existing files extended

- `Sources/PatternEngine/StrokeSample.swift` — normalized input values and
  capabilities.
- `Sources/PatternEngine/BrushRecipe.swift` — temporary compatibility recipe.
- `Sources/PatternEngine/BrushDynamicsEngine.swift` — logical-dab evaluation.
- `Sources/PatternEngine/BrushStrokeGenerator.swift` — authoritative ordered
  dab generation.
- `Sources/PatternEngine/TransientStrokeBuffer.swift` — bounded actual and
  predicted replay.
- `Sources/PatternEngine/Verification/StrokeTraceFixtures.swift` — stable
  platform-free input traces.
- `Sources/EditorCore/Brushes/AnchorBrushCatalog.swift` — built-in
  compatibility definitions and precompiled pure programs.
- `Sources/PatternFile/PatternProjectArchive.swift` — project-specific wrapper
  over extracted safe archive machinery.
- `Sources/MetalRenderer/BenchmarkRecord.swift` and
  `Sources/MetalRenderer/Capture/SliceFourHarnessRunner.swift` —
  characterization evidence.
- `Sources/MetalRenderer/GridRenderer.swift` — consumes a precompiled pure
  program while retaining the current raster backend.
- `App/PatternSpike/Input/BrushInputAdapter.swift` and canvas hosts — native
  Pencil/Wacom extraction only.
- `Package.swift` and `App/project.yml` — new modules and iPadOS 18 baseline.

### New focused units

- `Sources/PatternEngine/BrushModel/BrushDefinition.swift` — immutable native
  brush semantics.
- `Sources/PatternEngine/BrushModel/BrushProgram.swift` — validated,
  renderer-free compiled program.
- `Sources/PatternEngine/BrushModel/BrushProgramCompiler.swift` — pure
  definition-to-program compilation.
- `Sources/PatternEngine/BrushModel/LegacyBrushRecipeAdapter.swift` — exact
  temporary bridge in both directions.
- `Sources/PatternEngine/BrushModel/LogicalDabBatch.swift` — bounded ordered
  batch and transformed stamp frame.
- `Sources/PatternEngine/Verification/BrushCharacterization.swift` — stable
  logical output fingerprinting.
- `Sources/SafeArchive/` — reusable deterministic stored-ZIP codec and atomic
  I/O.
- `Sources/BrushFormat/` — `.layabrush` manifest, resource validation, codec,
  and I/O.
- `Sources/MetalRenderer/BrushCompiler/` — image decode, device profile,
  resource-cost estimate, private texture upload, LRU residency, and compiled
  Metal brush.

All `.fixture` members shown below are private helpers declared in the same
test file. `AnchorRecipeFixtures` is the one shared test-only helper and lives
under `Tests/PatternEngineTests/Support`; none of these are production APIs.

### Approved-spec coverage

- Stage 1 characterization, negative controls, timing/memory evidence:
  Tasks 1, 2, and 12.
- Normalized Pencil/Wacom input and replaceable prediction/estimation:
  Task 8.
- Immutable, future-facing definition and deterministic pure program:
  Tasks 4 and 5.
- Fully evaluated logical dabs with whole-frame symmetry:
  Task 6.
- Secure native package with lossless sources and disposable device caches:
  Tasks 3, 7, 9, and 10.
- Async/cancelable compilation, explicit compatibility/resource reports,
  pipeline keys, uniform templates, and bounded residency:
  Tasks 9 and 10.
- Exact current-brush adapter with no intended pixel change:
  Task 11 and the Task 12 gate.
- Converter, Brush Lab, new deposition pipelines, Wet Mix, public editor, and
  final hardware calibration remain in Stages 3–7 exactly as the approved spec
  requires.

---

### Task 1: Pin Deterministic Logical-Dab Characterization

**Files:**

- Modify: `Package.swift`
- Create:
  `Sources/PatternEngine/Verification/BrushCharacterization.swift`
- Create:
  `Sources/BrushCharacterizationTool/main.swift`
- Modify:
  `Sources/PatternEngine/Verification/StrokeTraceFixtures.swift:20-147`
- Create:
  `Tests/PatternEngineTests/BrushCharacterizationTests.swift`
- Create:
  `Tests/EditorCoreTests/AnchorBrushCharacterizationTests.swift`
- Create:
  `Tests/EditorCoreTests/Fixtures/brush-logical-v1.json`

**Interfaces:**

- Consumes:
  `StrokeTraceFixture`, `BrushRecipe`, `BrushInputDeriver`,
  `BrushStrokeGenerator`, `ViewportTransform`.
- Produces:

```swift
public struct BrushCharacterizationRecord:
    Codable, Equatable, Sendable
{
    public let schemaVersion: UInt16
    public let traceName: String
    public let recipeID: String
    public let nominalDiameter: Float
    public let seed: UInt64
    public let sampleCount: Int
    public let logicalDabCount: Int
    public let logicalDabDigest: String
}

public enum BrushCharacterizer {
    public static func record(
        trace: StrokeTraceFixture,
        recipe: BrushRecipe,
        nominalDiameter: Float,
        color: InkColor,
        seed: UInt64,
        viewport: ViewportTransform
    ) -> BrushCharacterizationRecord
}

public struct BrushLogicalBaseline:
    Codable, Equatable, Sendable
{
    public let schemaVersion: UInt16
    public let records: [BrushCharacterizationRecord]

    public init(
        validatingSchemaVersion schemaVersion: UInt16,
        records: [BrushCharacterizationRecord]
    ) throws

    public func requireMatches(
        _ actual: [BrushCharacterizationRecord]
    ) throws
}
```

- The digest is lowercase, fixed-width, 16-character FNV-1a-64 over a
  versioned byte stream. Append every scalar by its IEEE bit pattern in this
  exact order: ordinal, position x/y, all three `brushToWorld` columns, radius,
  diameter, spacing, flow, stroke opacity, rotation, scatter x/y, hardness,
  grain offset x/y, grain scale, grain rotation, color RGBA, color-adjustment
  RGBA, material-family raw value, material contribution, source distance, and
  prediction flag. Then append the Stage 2 extension payload: presence tags
  and derived primary/secondary grain-frame columns, secondary-color mix,
  accumulation/interaction/edge tags and material scalars, the five
  compatibility random values, ten zeroed extension-random channels, and
  conservative world-bounds min/max. Prefix the stream with characterization
  schema version `1`.

  During Task 1 those extension values are derived from the current recipe,
  dab, seed, and ordinal without changing renderer types. Task 6 stores the
  same values directly on `LogicalDab` and proves the digest remains identical.

- [ ] **Step 1: Write failing pure characterization tests**

```swift
@Test
func characterizationIsStableAndSensitiveToSeed() {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 256, height: 256),
        worldCenter: WorldPoint(x: 128, y: 128)
    )
    let first = BrushCharacterizer.record(
        trace: .pressureRamp,
        recipe: .legacyEquivalent,
        nominalDiameter: 20,
        color: .black,
        seed: 41,
        viewport: viewport
    )
    let repeated = BrushCharacterizer.record(
        trace: .pressureRamp,
        recipe: .legacyEquivalent,
        nominalDiameter: 20,
        color: .black,
        seed: 41,
        viewport: viewport
    )
    let changed = BrushCharacterizer.record(
        trace: .pressureRamp,
        recipe: try! BrushRecipe(
            id: BrushRecipeID("characterization.random"),
            randomization: BrushRandomization(
                spacing: 0.2,
                scatter: 1,
                rotation: 1,
                grain: 1,
                material: 1
            )
        ),
        nominalDiameter: 20,
        color: .black,
        seed: 42,
        viewport: viewport
    )

    #expect(first == repeated)
    #expect(first.schemaVersion == 1)
    #expect(first.sampleCount == 4)
    #expect(first.logicalDabCount > 0)
    #expect(first.logicalDabDigest.count == 16)
    #expect(first.logicalDabDigest != changed.logicalDabDigest)
}
```

- Add `predictionCorrection` to `StrokeTraceFixtures`: one actual begin,
  two coalesced moves, two predicted moves, replacement actual moves, and one
  actual end. The committed characterization passes only the actual/coalesced
  prefix and replacement actual suffix to the authoritative generator.

- [ ] **Step 2: Run tests and verify the API is absent**

Run:

```bash
swift test --filter BrushCharacterizationTests
```

Expected: compilation fails because `BrushCharacterizer` and
`predictionCorrection` do not exist.

- [ ] **Step 3: Implement fixed-byte characterization**

Implement a private digest accumulator with explicit little-endian append
methods:

```swift
private struct FNV1a64 {
    private var value: UInt64 = 0xcbf29ce484222325

    mutating func append(_ value: UInt64) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            for byte in bytes {
                self.value ^= UInt64(byte)
                self.value &*= 0x100000001b3
            }
        }
    }

    mutating func append(_ value: Float) {
        append(UInt64(value.bitPattern))
    }

    var hex: String {
        String(format: "%016llx", value)
    }
}
```

`BrushCharacterizer.record` must instantiate one input deriver and one
generator, process lifecycle phases in order, ignore predicted samples for the
authoritative record, and precondition that the trace begins and ends exactly
once.

- [ ] **Step 4: Pin all five current anchor recipes**

In `AnchorBrushCharacterizationTests.swift`, characterize
`AnchorBrushCatalog.all` against `pressureRamp`, `curved`, and
`predictionCorrection`. Assert:

```swift
#expect(records.count == 15)
#expect(Set(records.map(\.recipeID)).count == 5)
#expect(Set(records.map(\.logicalDabDigest)).count >= 10)
#expect(records.allSatisfy { $0.logicalDabCount > 0 })
```

Add an executable target `BrushCharacterizationTool` depending on
`PatternEngine` and `EditorCore`. It emits these 15 records sorted by
`(recipeID, traceName)` as sorted-key JSON. Generate the checked-in fixture
from the unchanged renderer-independent path:

```bash
mkdir -p Tests/EditorCoreTests/Fixtures
swift run BrushCharacterizationTool \
  > Tests/EditorCoreTests/Fixtures/brush-logical-v1.json
```

Declare the fixture as an `EditorCoreTests` copied resource. Tests load it
through `Bundle.module`, validate exact count/order/uniqueness, compare every
record exactly, and encode/decode/encode to identical bytes. Mutating one
digest in memory must fail closed.

- [ ] **Step 5: Run focused and full pure tests**

Run:

```bash
swift test --filter BrushCharacterization
swift test --no-parallel --filter PatternEngineTests
swift test --no-parallel --filter EditorCoreTests
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit**

```bash
git add \
  Package.swift \
  Sources/PatternEngine/Verification/BrushCharacterization.swift \
  Sources/BrushCharacterizationTool/main.swift \
  Sources/PatternEngine/Verification/StrokeTraceFixtures.swift \
  Tests/PatternEngineTests/BrushCharacterizationTests.swift \
  Tests/EditorCoreTests/AnchorBrushCharacterizationTests.swift \
  Tests/EditorCoreTests/Fixtures/brush-logical-v1.json
git commit -m "test(brush): pin logical dab baseline"
```

---

### Task 2: Record Renderer Characterization Evidence

**Files:**

- Create:
  `Sources/MetalRenderer/Capture/BrushCharacterizationEvidence.swift`
- Modify:
  `Sources/MetalRenderer/BenchmarkRecord.swift:221-420`
- Modify:
  `Sources/MetalRenderer/Capture/SliceFourHarnessRunner.swift:186-520`
- Modify:
  `Tests/MetalRendererTests/BenchmarkRecordTests.swift:151-249`
- Modify:
  `Tests/MetalRendererTests/SliceFourHarnessRunnerTests.swift:8-250`
- Create:
  `Tests/MetalRendererTests/BrushCharacterizationEvidenceTests.swift`
- Create:
  `App/PatternSpike/Harness/Baselines/brush-foundation-v1.json`

**Interfaces:**

- Consumes: Task 1 `BrushCharacterizationRecord`, Slice 4 scenes, canonical
  BGRA bytes, existing benchmark metrics.
- Produces:

```swift
public struct BrushCharacterizationEvidence:
    Codable, Equatable, Sendable
{
    public static let currentVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let sceneName: String
    public let logical: BrushCharacterizationRecord
    public let canonicalWidth: Int
    public let canonicalHeight: Int
    public let canonicalBGRA8Digest: String
    public let resolvedShapeIdentity: String
    public let resolvedGrainIdentity: String
}

public struct BrushCharacterizationBaseline:
    Codable, Equatable, Sendable
{
    public let schemaVersion: UInt16
    public let records: [BrushCharacterizationEvidence]
}
```

- Add append-only schema-6 fields to `BenchmarkRecord`:
  `brushCharacterizationVersion`, `logicalDabDigest`,
  `canonicalBGRA8Digest`, `inputSampleCount`, and `logicalDabCount`.
  Schema 1–5 decoding remains unchanged; all five fields are required and
  validated for schema 6.

- Canonical digest uses the same FNV byte algorithm but includes width, height,
  pixel format tag `1`, row-major BGRA bytes, and no platform metadata.

- [ ] **Step 1: Write failing record and baseline tests**

```swift
@Test
func baselineRejectsDuplicateSceneAndMalformedDigest() throws {
    let valid = BrushCharacterizationEvidence.fixture(scene: "ink")
    #expect(throws: BrushCharacterizationEvidenceError.self) {
        try BrushCharacterizationBaseline.validated(
            schemaVersion: 1,
            records: [valid, valid]
        )
    }
    #expect(throws: BrushCharacterizationEvidenceError.self) {
        try BrushCharacterizationEvidence.validated(
            schemaVersion: 1,
            sceneName: "ink",
            logical: valid.logical,
            canonicalWidth: 64,
            canonicalHeight: 64,
            canonicalBGRA8Digest: "not-a-digest",
            resolvedShapeIdentity: "builtin.shape.hard-round",
            resolvedGrainIdentity: "builtin.grain.opaque"
        )
    }
}
```

Extend the benchmark schema matrix so deleting any new schema-6 key throws
`BenchmarkRecordError.missingSchemaSixMetric(key)`.

- [ ] **Step 2: Run focused tests to observe failures**

Run:

```bash
swift test --filter BrushCharacterizationEvidenceTests
swift test --filter BenchmarkRecordTests
```

Expected: compilation fails on the new evidence and schema-6 APIs.

- [ ] **Step 3: Implement evidence validation and harness output**

For the eight Slice 4 scenes, compute the logical record from the scene's
attributed samples and selected recipe, digest the actual canonical readback,
and write:

```text
<output>/<scene>.brush-characterization.json
```

Write the file atomically beside the existing PNG and benchmark artifacts.
`SliceFourHarnessRunner` must report the same recipe ID, seed, sample count,
and logical dab count in both characterization and benchmark records.

- [ ] **Step 4: Generate the checked-in baseline from the unchanged renderer**

After the Task 2 implementation tests pass, generate this characterization
fixture from the unchanged rendering path. This creates a development fixture,
not final provenance; Task 12 regenerates evidence from clean committed source:

```bash
./scripts/bootstrap.sh
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination platform=macOS \
  -derivedDataPath .build/DerivedData \
  build CODE_SIGNING_ALLOWED=NO

mkdir -p .build/brush-foundation-baseline
for scene in \
  slice4-legacy-ink-parity \
  slice4-pressure-scatter \
  slice4-dry-grain-tilings \
  slice4-glaze-live-commit \
  slice4-wash-bounds \
  slice4-prediction-taper-replay \
  slice4-stale-epoch-cancel \
  slice4-long-stroke-bounds
do
  .build/DerivedData/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike \
    --harness-scene "App/PatternSpike/Harness/Scenes/$scene.json" \
    --output-directory ".build/brush-foundation-baseline/$scene" \
    --git-commit "$(git rev-parse HEAD)" \
    --configuration Debug
done

jq -s \
  '{schemaVersion: 1, records: sort_by(.sceneName)}' \
  .build/brush-foundation-baseline/*/*.brush-characterization.json \
  > App/PatternSpike/Harness/Baselines/brush-foundation-v1.json
```

Validate:

```bash
jq -e '
  .schemaVersion == 1 and
  (.records | length) == 8 and
  ([.records[].sceneName] | unique | length) == 8 and
  ([.records[].canonicalBGRA8Digest |
    test("^[0-9a-f]{16}$")] | all)
' App/PatternSpike/Harness/Baselines/brush-foundation-v1.json
```

Expected: `true`.

- [ ] **Step 5: Make the harness fail closed against the baseline**

Add a test that loads the checked-in baseline, reruns each positive scene,
and compares semantic fields and digests. Mutate one digest in memory and
assert `BrushCharacterizationEvidenceError.digestMismatch`.

- [ ] **Step 6: Run the Slice 4 characterization tests**

Run:

```bash
swift test --no-parallel --filter BrushCharacterization
swift test --no-parallel --filter SliceFourHarnessRunnerTests
```

Expected: positive records equal the baseline and the mutated record fails.

- [ ] **Step 7: Commit**

```bash
git add \
  Sources/MetalRenderer/BenchmarkRecord.swift \
  Sources/MetalRenderer/Capture/BrushCharacterizationEvidence.swift \
  Sources/MetalRenderer/Capture/SliceFourHarnessRunner.swift \
  Tests/MetalRendererTests/BenchmarkRecordTests.swift \
  Tests/MetalRendererTests/BrushCharacterizationEvidenceTests.swift \
  Tests/MetalRendererTests/SliceFourHarnessRunnerTests.swift \
  App/PatternSpike/Harness/Baselines/brush-foundation-v1.json
git commit -m "test(brush): record renderer baseline"
```

---

### Task 3: Extract The Reusable Safe Archive Layer

**Files:**

- Create: `Sources/SafeArchive/SafeArchive.swift`
- Create: `Sources/SafeArchive/SafeArchiveCodec.swift`
- Create: `Sources/SafeArchive/SafeArchiveIO.swift`
- Create: `Sources/SafeArchive/CRC32.swift`
- Create: `Sources/SafeArchive/Data+LittleEndian.swift`
- Create: `Tests/SafeArchiveTests/SafeArchiveCodecTests.swift`
- Create: `Tests/SafeArchiveTests/SafeArchiveIOTests.swift`
- Modify: `Sources/PatternFile/PatternProjectArchive.swift:1-650`
- Modify: `Tests/PatternFileTests/PatternProjectArchiveTests.swift:1-420`
- Modify: `Package.swift:8-82`

**Interfaces:**

```swift
public struct SafeArchiveLimits: Equatable, Sendable {
    public let maximumEntryCount: Int
    public let maximumEntryBytes: UInt64
    public let maximumExpandedBytes: UInt64
    public let maximumPathBytes: Int
}

public struct SafeArchive: Sendable {
    public let paths: [String]
    public func data(for path: String) throws -> Data
}

public enum SafeArchiveCodec {
    public static func encode(
        entries: [String: Data],
        limits: SafeArchiveLimits
    ) throws -> Data

    public static func open(
        _ data: Data,
        limits: SafeArchiveLimits
    ) throws -> SafeArchive
}

public enum SafeArchiveIO {
    public static func save(
        entries: [String: Data],
        to destination: URL,
        limits: SafeArchiveLimits
    ) throws
}
```

- Stored ZIP only, deterministic path sorting and fixed 1980 timestamp.
- Reject ZIP64, encryption, data descriptors, unsupported compression,
  duplicate entries, absolute/backslash/dot paths, symbolic links, directory
  entries, CRC mismatch, entry count overflow, entry byte overflow, and total
  expanded-byte overflow.
- `PatternProjectArchiveCodec` remains source-compatible and maps
  `SafeArchiveError` to the existing `PatternProjectArchiveError` cases.

- [ ] **Step 1: Add the target and failing generic archive tests**

Add `SafeArchive` and `SafeArchiveTests` to `Package.swift`. Test deterministic
encoding and every rejection family using small mutated byte arrays:

```swift
@Test
func encodingIsDeterministicAndSorted() throws {
    let limits = SafeArchiveLimits.testing
    let first = try SafeArchiveCodec.encode(
        entries: ["b.bin": Data([2]), "a.bin": Data([1])],
        limits: limits
    )
    let second = try SafeArchiveCodec.encode(
        entries: ["a.bin": Data([1]), "b.bin": Data([2])],
        limits: limits
    )
    #expect(first == second)
    let archive = try SafeArchiveCodec.open(first, limits: limits)
    #expect(archive.paths == ["a.bin", "b.bin"])
    #expect(try archive.data(for: "a.bin") == Data([1]))
}
```

- [ ] **Step 2: Run the new tests and observe missing symbols**

Run:

```bash
swift test --filter SafeArchiveTests
```

Expected: compilation fails because the target API is absent.

- [ ] **Step 3: Move the ZIP primitives without behavior changes**

Move the parsing/writing logic from `PatternProjectArchive.swift` into the
five SafeArchive files. Parameterize the four numeric limits; do not add
compression or ZIP64. Keep checked integer arithmetic and CRC behavior
byte-for-byte.

- [ ] **Step 4: Convert PatternFile to a compatibility wrapper**

Use these project limits:

```swift
private static let limits = SafeArchiveLimits(
    maximumEntryCount: 16_384,
    maximumEntryBytes: 256 * 1_024 * 1_024,
    maximumExpandedBytes: 1_024 * 1_024 * 1_024,
    maximumPathBytes: 512
)
```

Retain all public `PatternProjectArchive*` names. Existing callers and tests
must compile unchanged.

- [ ] **Step 5: Run generic and project archive suites**

Run:

```bash
swift test --no-parallel --filter SafeArchiveTests
swift test --no-parallel --filter PatternProjectArchiveTests
swift test --no-parallel --filter PatternFileTests
```

Expected: all tests pass, including injected atomic-save failure.

- [ ] **Step 6: Commit**

```bash
git add \
  Package.swift \
  Sources/SafeArchive \
  Tests/SafeArchiveTests \
  Sources/PatternFile/PatternProjectArchive.swift \
  Tests/PatternFileTests/PatternProjectArchiveTests.swift
git commit -m "refactor(archive): share safe package codec"
```

---

### Task 4: Add Immutable Native Brush Definitions

**Files:**

- Create:
  `Sources/PatternEngine/BrushModel/BrushDefinition.swift`
- Create:
  `Sources/PatternEngine/BrushModel/LegacyBrushRecipeAdapter.swift`
- Create:
  `Tests/PatternEngineTests/BrushDefinitionTests.swift`
- Create:
  `Tests/PatternEngineTests/Support/AnchorRecipeFixtures.swift`
- Modify:
  `Sources/PatternEngine/BrushRecipe.swift:4-473`

**Interfaces:**

```swift
public enum BrushCapability: String, Codable, CaseIterable, Sendable {
    case dualShape
    case dualGrain
    case packagedShape
    case packagedGrain
    case canvasInteraction
    case smudge
    case wetMix
}

public struct BrushCapabilityDeclaration:
    Codable, Equatable, Sendable
{
    public let identifier: String
    public let required: Bool
}

public struct BrushMetadata: Codable, Equatable, Sendable {
    public let displayName: String
    public let author: String?
    public let sourceApplication: String?
    public let sourceIdentifier: String?
}

public enum BrushResourceKind:
    String, Codable, Hashable, Sendable
{
    case shape
    case grain
    case preview
}

public enum BrushResourceFallback:
    Codable, Equatable, Hashable, Sendable
{
    case builtIn(identifier: String)
}

public struct BrushResourceReference:
    Codable, Equatable, Hashable, Sendable
{
    public let identifier: String
    public let kind: BrushResourceKind
    public let required: Bool
    public let fallback: BrushResourceFallback?
}

public enum BrushShapeCombinationMode:
    String, Codable, Equatable, Sendable
{
    case replace
    case multiply
    case minimum
    case maximum
}

public struct BrushShapeLayerDefinition:
    Codable, Equatable, Sendable
{
    public let shape: BrushShapeDescriptor
    public let combination: BrushShapeCombinationMode
    public let scale: Float
    public let rotation: Float
    public let offset: SIMD2<Float>
}

public struct BrushGrainLayerDefinition:
    Codable, Equatable, Sendable
{
    public let grain: BrushGrainDescriptor
    public let coordinateMode: BrushGrainCoordinateMode
    public let transform: BrushGrainTransform
    public let grainMovementFraction: Float
    public let grainFollowsBrushRotation: Bool
    public let strength: Float
}

public struct BrushCoverageDefinition: Codable, Equatable, Sendable {
    public let shapes: [BrushShapeLayerDefinition]
    public let grains: [BrushGrainLayerDefinition]
    public let baseHardness: Float
    public let aspectRatio: Float
    public let tipThreshold: Float
    public let antialiasing: Bool
}

public enum BrushAccumulationMode:
    String, Codable, Hashable, Sendable
{
    case opaque
    case flow
    case uniformGlaze
    case intenseGlaze
    case destinationOut
}

public enum BrushInteractionMode:
    String, Codable, Equatable, Sendable
{
    case none
    case pickup
    case smudge
    case wetMix
}

public enum BrushEdgeTreatment:
    String, Codable, Hashable, Sendable
{
    case none
    case dryBreakup
    case markerOverlap
    case wetConcentration
}

public struct BrushInteractionDefinition:
    Codable, Equatable, Sendable
{
    public let pickup: Float
    public let pull: Float
    public let dilution: Float
    public let charge: Float
    public let persistence: Float
    public let dirtyHaloRadius: Float
}

public struct BrushMaterialDefinition: Codable, Equatable, Sendable {
    public let accumulation: BrushAccumulationMode
    public let interaction: BrushInteractionMode
    public let edgeTreatment: BrushEdgeTreatment
    public let strength: Float
    public let wetness: Float
    public let bleedRadius: Float
    public let softenPasses: Int
    public let accumulationLimit: Float
    public let interactionParameters: BrushInteractionDefinition?
}

public struct BrushPlacementDefinition: Codable, Equatable, Sendable {
    public let baseSpacingFraction: Float
    public let maximumSpacingFraction: Float
    public let baseFlow: Float
    public let strokeOpacity: Float
    public let baseScatterFraction: Float
    public let baseRotation: Float
    public let baseJitterFraction: Float
    public let baseOffset: SIMD2<Float>
}

public enum BrushDynamicsInput:
    String, Codable, CaseIterable, Equatable, Sendable
{
    case pressure
    case speed
    case direction
    case tilt
    case azimuth
    case roll
    case tangentialPressure
    case age
    case distance
    case random
}

public struct BrushCurvePoint: Codable, Equatable, Sendable {
    public let x: Float
    public let y: Float
}

public struct BrushCurveDefinition: Codable, Equatable, Sendable {
    public let points: [BrushCurvePoint]
}

public enum BrushResponseDefinition: Codable, Equatable, Sendable {
    case constant(Float)
    case linear
    case boundedPower(exponent: Float)
    case curve(BrushCurveDefinition)
}

public struct BrushMappingDefinition: Codable, Equatable, Sendable {
    public let input: BrushDynamicsInput
    public let response: BrushResponseDefinition
    public let scale: Float
    public let offset: Float
    public let lowerClamp: Float
    public let upperClamp: Float
    public let inverted: Bool
    public let jitter: Float
    public let missingInputValue: Float
}

public struct BrushDynamicsDefinition: Codable, Equatable, Sendable {
    public let size: BrushMappingDefinition
    public let flow: BrushMappingDefinition
    public let opacity: BrushMappingDefinition
    public let spacing: BrushMappingDefinition
    public let rotation: BrushMappingDefinition
    public let scatter: BrushMappingDefinition
    public let hardness: BrushMappingDefinition
    public let grain: BrushMappingDefinition
    public let offsetX: BrushMappingDefinition
    public let offsetY: BrushMappingDefinition
    public let hue: BrushMappingDefinition
    public let saturation: BrushMappingDefinition
    public let brightness: BrushMappingDefinition
    public let secondaryColorMix: BrushMappingDefinition
    public let noPressureNeutral: Float
    public let randomization: BrushRandomization
}

public struct BrushColorJitter: Codable, Equatable, Sendable {
    public let hue: Float
    public let saturation: Float
    public let brightness: Float
    public let secondaryColorMix: Float
}

public struct BrushColorBehaviorDefinition:
    Codable, Equatable, Sendable
{
    public let baseAdjustment: BrushColorAdjustment
    public let perStampJitter: BrushColorJitter
    public let perStrokeJitter: BrushColorJitter
}

public enum BrushSeedPolicy: Codable, Equatable, Sendable {
    case perStroke
    case fixed(UInt64)
}

public enum BrushPerformanceIntent:
    String, Codable, Equatable, Sendable
{
    case realtime120
    case realtime60
    case quality
}

public struct BrushDefinitionLimits: Codable, Equatable, Sendable {
    public let minimumDiameter: Float
    public let maximumDiameter: Float
    public let maximumOpacity: Float
    public let maximumSpacingFraction: Float
    public let maximumResourceDimension: Int
    public let maximumResidentBytes: Int
}

public struct BrushCompatibilityMetadata:
    Codable, Equatable, Sendable
{
    public let nativeFeatureVersion: UInt16
    public let sourceSettingKeys: [String]
    public let requiredSemanticKeys: [String]
}

public struct BrushDefinition: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let id: BrushRecipeID
    public let schemaVersion: UInt16
    public let metadata: BrushMetadata
    public let capabilities: [BrushCapabilityDeclaration]
    public let resources: [BrushResourceReference]
    public let coverage: BrushCoverageDefinition
    public let placement: BrushPlacementDefinition
    public let dynamics: BrushDynamicsDefinition
    public let color: BrushColorBehaviorDefinition
    public let material: BrushMaterialDefinition
    public let stabilization: Float
    public let taper: BrushTaperConfiguration
    public let replayMode: BrushReplayMode
    public let replayLimits: BrushReplayLimits?
    public let seedPolicy: BrushSeedPolicy
    public let limits: BrushDefinitionLimits
    public let performanceIntent: BrushPerformanceIntent
    public let compatibility: BrushCompatibilityMetadata
}

public enum LegacyBrushRecipeAdapter {
    public static func definition(
        from recipe: BrushRecipe,
        displayName: String
    ) throws -> BrushDefinition

    public static func recipe(
        from definition: BrushDefinition
    ) throws -> BrushRecipe
}
```

- Add deliberate `Codable` conformance to the existing recipe leaf types.
  `BrushShapeDescriptor`, `BrushGrainDescriptor`, and `BrushTaperLength` use
  explicit tagged encodings; do not rely on compiler-synthesized
  associated-value keys. Apply the same tagged rule to every new
  associated-value enum. `SIMD2<Float>` values encode as
  `{ "x": ..., "y": ... }`.

- Capability declarations are stored sorted by identifier with duplicates
  rejected. Known identifiers map to `BrushCapability`; unknown optional
  declarations survive round-trip and produce a diagnostic, while an unknown
  required declaration fails compilation. This keeps bytes deterministic and
  permits safe forward compatibility.
- Compatibility setting-key arrays are sorted and unique. Curve points have
  strictly increasing `x`, both axes stay in `0...1`, endpoints include
  `x == 0` and `x == 1`, and the maximum point count is 32.
- A constant response is already its final output and therefore requires
  canonical neutral affine/inversion/jitter fields; all mappings require
  ordered finite clamps and a bounded missing-input value.
- Coverage contains one or two shape layers and zero, one, or two grain
  layers. The first shape uses `.replace`; a second layer uses a combining
  operation. Legacy anchors compile to one identity shape and at most one
  identity grain, while the schema is ready for Procreate-style dual brushes.
- Optional shape/grain resources require an explicit kind-matched built-in
  fallback. Required shape/grain resources reject a fallback. Preview
  resources are optional package metadata, carry no fallback, and cannot be
  referenced by coverage.
- Validation rejects empty IDs/names, duplicate resource identifiers,
  kind-mismatched shape/grain references, nonfinite scalars, ranges outside
  current `BrushRecipePolicy`, invalid definition limits, interaction
  capabilities or parameters missing from `capabilities`, and replay/taper
  violations.

- [ ] **Step 1: Write failing definition and exact-adapter tests**

```swift
@Test(arguments: AnchorRecipeFixtures.all)
func legacyRecipeRoundTripsExactly(_ fixture: AnchorRecipeFixture) throws {
    let definition = try LegacyBrushRecipeAdapter.definition(
        from: fixture.recipe,
        displayName: fixture.displayName
    )
    let roundTrip = try LegacyBrushRecipeAdapter.recipe(from: definition)

    #expect(roundTrip == fixture.recipe)
    #expect(definition.id == fixture.recipe.id)
    #expect(definition.resources.map(\.identifier).sorted()
        == definition.resources.map(\.identifier))
}

@Test
func definitionRejectsWetInteractionWithoutCapability() {
    #expect(throws: BrushDefinitionValidationError.self) {
        try BrushDefinition.fixture(
            capabilities: [],
            interaction: .wetMix
        )
    }
}
```

Add parameterized rejection tests for unsorted capabilities and setting keys,
duplicate resource IDs, an optional resource without fallback, a fallback of
the wrong kind, preview use as a coverage source, nonfinite or unsorted curve
points, invalid limits, fixed seed `0`, and interaction parameters without the
matching capability.

Create `AnchorRecipeFixtures` from local copies of the five existing anchor
recipes. Keep it under test support so Task 5 can reuse it; do not add an
EditorCore dependency to PatternEngine tests.

- [ ] **Step 2: Run tests and observe the missing model**

Run:

```bash
swift test --filter BrushDefinitionTests
```

Expected: compilation fails because `BrushDefinition` and adapter types are
absent.

- [ ] **Step 3: Implement explicit encoding and validation**

Implement custom encoders for associated-value recipe leaves with stable tags:

```json
{ "kind": "asset", "identifier": "package.shape.ink-01" }
{ "kind": "worldPixels", "value": 24.0 }
```

Use `JSONEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`
in tests and prove encode/decode/encode produces identical bytes.

- [ ] **Step 4: Implement the exact legacy bridge**

Mapping rules for current anchors:

- `.ink` -> `.flow`, `.none`, `.none`
- `.dry` -> `.flow`, `.none`, `.dryBreakup`
- `.glaze` -> `.uniformGlaze`, `.none`, `.markerOverlap`
- `.boundedWash` -> `.flow`, `.none`, `.wetConcentration`

Bounded wash remains a deposition compatibility material here; it does not
claim `.wetMix`.

The adapter maps each old `BrushMapping` into a native constant, linear, or
bounded-power definition whose affine/clamp values exactly express the old
output range. New-only fields receive explicit neutral values. Reverse
adaptation succeeds only when every definition field is exactly representable
by `BrushRecipe`; it throws for curves, dual shapes, color jitter, interaction,
nondefault limits/seed/performance intent, nonneutral compatibility metadata,
or any other semantic loss. The forward adapter uses one documented canonical
compatibility default for each field absent from `BrushRecipe`.

- [ ] **Step 5: Run model, recipe, and characterization parity**

Run:

```bash
swift test --filter BrushDefinitionTests
swift test --filter BrushRecipeTests
swift test --filter AnchorBrushCharacterizationTests
```

Expected: all tests pass and Task 1 digests remain unchanged.

- [ ] **Step 6: Commit**

```bash
git add \
  Sources/PatternEngine/BrushRecipe.swift \
  Sources/PatternEngine/BrushModel/BrushDefinition.swift \
  Sources/PatternEngine/BrushModel/LegacyBrushRecipeAdapter.swift \
  Tests/PatternEngineTests/BrushDefinitionTests.swift \
  Tests/PatternEngineTests/Support/AnchorRecipeFixtures.swift
git commit -m "feat(brush): add native brush definition"
```

---

### Task 5: Compile Definitions Into Pure Brush Programs

**Files:**

- Create: `Sources/PatternEngine/BrushModel/BrushProgram.swift`
- Create: `Sources/PatternEngine/BrushModel/BrushProgramCompiler.swift`
- Create: `Tests/PatternEngineTests/BrushProgramCompilerTests.swift`
- Modify: `Sources/PatternEngine/BrushRandom.swift`
- Modify: `Sources/PatternEngine/BrushDynamicsEngine.swift:144-380`
- Modify: `Sources/PatternEngine/BrushStrokeGenerator.swift:1-275`
- Modify: `Tests/PatternEngineTests/BrushRandomTests.swift`
- Modify: `Tests/PatternEngineTests/BrushDynamicsEngineTests.swift`
- Modify: `Tests/PatternEngineTests/BrushStrokeGeneratorTests.swift`

**Interfaces:**

```swift
public enum CompiledBrushResponse: Equatable, Sendable {
    case constant(Float)
    case legacyLinear(
        input: BrushDynamicsInput,
        minimum: Float,
        maximum: Float,
        missingInputValue: Float
    )
    case legacyBoundedPower(
        input: BrushDynamicsInput,
        minimum: Float,
        maximum: Float,
        exponent: Float,
        missingInputValue: Float
    )
    case sampledCurve(
        input: BrushDynamicsInput,
        samples: [Float],
        scale: Float,
        offset: Float,
        lowerClamp: Float,
        upperClamp: Float,
        inverted: Bool,
        jitter: Float,
        missingInputValue: Float
    )
}

public struct BrushDynamicsProgram: Equatable, Sendable {
    public let size: CompiledBrushResponse
    public let flow: CompiledBrushResponse
    public let opacity: CompiledBrushResponse
    public let spacing: CompiledBrushResponse
    public let rotation: CompiledBrushResponse
    public let scatter: CompiledBrushResponse
    public let hardness: CompiledBrushResponse
    public let grain: CompiledBrushResponse
    public let offsetX: CompiledBrushResponse
    public let offsetY: CompiledBrushResponse
    public let hue: CompiledBrushResponse
    public let saturation: CompiledBrushResponse
    public let brightness: CompiledBrushResponse
    public let secondaryColorMix: CompiledBrushResponse
}

public enum BrushBackendKind:
    String, Codable, Hashable, Sendable
{
    case deposition
    case canvasInteraction
}

public struct BrushProgram: Equatable, Sendable {
    public let definition: BrushDefinition
    public let dynamics: BrushDynamicsProgram
    public let compatibilityRecipe: BrushRecipe?
    public let requiredCapabilities: Set<BrushCapability>
    public let ignoredOptionalCapabilityIdentifiers: [String]
    public let requestedBackend: BrushBackendKind
}

public enum BrushProgramCompiler {
    public static func compile(
        _ definition: BrushDefinition
    ) throws -> BrushProgram
}
```

- Compilation performs all validation and branch selection before drawing.
- Preserve the current arithmetic order with the two explicit `legacy` cases;
  the compatibility program must produce bit-identical Task 1 digests.
- Compile every general curve into exactly 256 `Float` samples, including both
  endpoints, using piecewise-linear interpolation and a defined lower-bound
  segment search. Linear or power mappings with inversion, jitter, or
  nonlegacy clamping use the same sampled representation.
- Existing five-channel `BrushRandom` consumption remains unchanged for
  compatibility programs. New mapping jitter uses a counter-based value keyed
  by `(strokeSeed, logicalDabOrdinal, outputChannel)` so enabling one new
  channel cannot perturb another channel or the compatibility stream.
- `BrushDynamicsEngine.evaluate` takes `BrushProgram`.
- `BrushDynamicsEngine` reads coverage, placement, dynamics, material,
  stabilization, taper, and replay values from `BrushProgram.definition`.
  `compatibilityRecipe` is present only when a definition can be represented
  exactly by the old renderer.
- Keep deprecated recipe-taking overloads during this plan; they immediately
  adapt and compile for source compatibility in tests only. Production
  stroke creation must use `BrushProgram`.
- `BrushStrokeGenerator` stores `program`; its recipe initializer remains a
  compatibility convenience marked unavailable to production call sites by
  the end of Task 11.

- [ ] **Step 1: Write failing compiler and parity tests**

```swift
@Test(arguments: AnchorRecipeFixtures.all)
func compiledProgramMatchesLegacyEvaluation(
    _ fixture: AnchorRecipeFixture
) throws {
    let definition = try LegacyBrushRecipeAdapter.definition(
        from: fixture.recipe,
        displayName: fixture.displayName
    )
    let program = try BrushProgramCompiler.compile(definition)

    let legacy = characterize(recipe: fixture.recipe, seed: 71)
    let compiled = characterize(program: program, seed: 71)
    #expect(compiled == legacy)
}
```

Add rejection tests for a malformed curve, missing required capability, and
unsupported schema version or unknown required capability. Add preservation
for an unknown optional capability, exact LUT samples for a three-point curve,
missing-input fallback tests, fixed/per-stroke seed tests, and a test proving
that adding hue jitter does not change scatter/spacing random values.

- [ ] **Step 2: Run focused tests to verify failure**

Run:

```bash
swift test --filter BrushProgramCompilerTests
```

Expected: compilation fails because `BrushProgramCompiler` is absent.

- [ ] **Step 3: Implement compile-time response specialization**

Map exact compatibility definitions first:

```swift
private extension BrushMappingDefinition {
    var isLegacyAffine: Bool {
        let upper = offset + scale
        return !inverted
            && jitter == 0
            && scale >= 0
            && lowerClamp == offset
            && upperClamp == upper
    }
}

switch mapping.response {
case .constant(let value):
    return .constant(value)
case .linear where mapping.isLegacyAffine:
    return .legacyLinear(
        input: mapping.input,
        minimum: mapping.offset,
        maximum: mapping.offset + mapping.scale,
        missingInputValue: mapping.missingInputValue
    )
case .boundedPower(let exponent) where mapping.isLegacyAffine:
    return .legacyBoundedPower(
        input: mapping.input,
        minimum: mapping.offset,
        maximum: mapping.offset + mapping.scale,
        exponent: exponent,
        missingInputValue: mapping.missingInputValue
    )
default:
    return compileSampledCurve(mapping)
}
```

`compileSampledCurve(_:)` samples the validated response, then returns the
`.sampledCurve` case with the mapping's input, affine values, clamp, inversion,
jitter, and missing-input fallback copied verbatim.

The old `BrushMapping` compatibility helper continues to map:

```swift
switch mapping.response {
case .disabled:
    return .constant(disabledValue)
case .linear:
    return .legacyLinear(
        input: mapping.input,
        minimum: mapping.outputMinimum,
        maximum: mapping.outputMaximum,
        missingInputValue: noPressureNeutral
    )
case .boundedPower:
    return .legacyBoundedPower(
        input: mapping.input,
        minimum: mapping.outputMinimum,
        maximum: mapping.outputMaximum,
        exponent: mapping.exponent,
        missingInputValue: noPressureNeutral
    )
}
```

`BrushDynamicsEngine` evaluates `CompiledBrushResponse` without rechecking
configuration ranges. General sampled curves interpolate adjacent table
entries with bounded indices; exact legacy cases retain their old operations.

- [ ] **Step 4: Switch generator internals to `BrushProgram`**

Add:

```swift
public init(
    program: BrushProgram,
    nominalDiameter: Float,
    color: InkColor,
    seed: UInt64
)
```

Replace internal `recipe` reads with the corresponding immutable definition
and compiled-dynamics fields. Do not force unwrap `compatibilityRecipe` in
PatternEngine. No output field or random-consumption order changes.

- [ ] **Step 5: Run all dynamics and characterization parity tests**

Run:

```bash
swift test --filter BrushProgramCompilerTests
swift test --filter BrushDynamicsEngineTests
swift test --filter BrushStrokeGeneratorTests
swift test --filter BrushCharacterization
```

Expected: all tests pass and every checked-in digest is unchanged.

- [ ] **Step 6: Commit**

```bash
git add \
  Sources/PatternEngine/BrushModel/BrushProgram.swift \
  Sources/PatternEngine/BrushModel/BrushProgramCompiler.swift \
  Sources/PatternEngine/BrushRandom.swift \
  Sources/PatternEngine/BrushDynamicsEngine.swift \
  Sources/PatternEngine/BrushStrokeGenerator.swift \
  Tests/PatternEngineTests/BrushProgramCompilerTests.swift \
  Tests/PatternEngineTests/BrushRandomTests.swift \
  Tests/PatternEngineTests/BrushDynamicsEngineTests.swift \
  Tests/PatternEngineTests/BrushStrokeGeneratorTests.swift
git commit -m "feat(brush): compile pure brush programs"
```

---

### Task 6: Introduce Ordered Logical-Dab Batches And Stamp Frames

**Files:**

- Create: `Sources/PatternEngine/BrushModel/LogicalDabBatch.swift`
- Create: `Tests/PatternEngineTests/LogicalDabBatchTests.swift`
- Modify: `Sources/PatternEngine/BrushDynamicsEngine.swift:74-142`
- Modify: `Sources/PatternEngine/BrushStrokeGenerator.swift:34-100`
- Modify: `Sources/PatternEngine/TransientStrokeBuffer.swift:12-63`
- Modify:
  `Sources/PatternEngine/Verification/BrushCharacterization.swift`
- Modify: `Tests/PatternEngineTests/TransientStrokeBufferTests.swift`
- Modify: `Tests/PatternEngineTests/BrushCharacterizationTests.swift`

**Interfaces:**

```swift
public typealias DabAttributes = LogicalDab

public struct BrushMaterialInputs: Equatable, Sendable {
    public let accumulation: BrushAccumulationMode
    public let interaction: BrushInteractionMode
    public let edgeTreatment: BrushEdgeTreatment
    public let strength: Float
    public let wetness: Float
    public let bleedRadius: Float
    public let accumulationLimit: Float
    public let interactionParameters: BrushInteractionDefinition?
}

public struct BrushLogicalRandomValues: Equatable, Sendable {
    public let compatibility: BrushRandomValues
    public let size: Float
    public let flow: Float
    public let opacity: Float
    public let hardness: Float
    public let offsetX: Float
    public let offsetY: Float
    public let hue: Float
    public let saturation: Float
    public let brightness: Float
    public let secondaryColorMix: Float
}

public struct LogicalDab: Equatable, Sendable {
    public let position: WorldPoint
    public let brushToWorld: Affine2D
    public let radius: Float
    public let diameter: Float
    public let spacing: Float
    public let flow: Float
    public let strokeOpacity: Float
    public let rotation: Float
    public let scatter: SIMD2<Float>
    public let hardness: Float
    public let grainOffset: SIMD2<Float>
    public let grainScale: Float
    public let grainRotation: Float
    public let color: InkColor
    public let colorAdjustment: BrushColorAdjustment
    public let materialFamily: BrushMaterialFamily
    public let materialContribution: Float
    public let sourceDistance: Float
    public let ordinal: UInt64
    public let isPredicted: Bool
    public let primaryGrainToWorld: Affine2D?
    public let secondaryGrainToWorld: Affine2D?
    public let secondaryColorMix: Float
    public let materialInputs: BrushMaterialInputs
    public let randomValues: BrushLogicalRandomValues
    public let worldBounds: AxisAlignedRect
}

public struct LogicalDabBatch: Equatable, Sendable {
    public let seed: UInt64
    public let dabs: [LogicalDab]
    public let ordinalRange: Range<UInt64>
    public let isPredicted: Bool
    public let worldBounds: AxisAlignedRect?

    public init(
        seed: UInt64,
        startingOrdinal: UInt64,
        isPredicted: Bool,
        dabs: [LogicalDab]
    ) throws
}

public struct TransformedStampFrame: Equatable, Sendable {
    public let logicalOrdinal: UInt64
    public let isometryOrdinal: UInt8
    public let brushToCanonical: Affine2D
    public let primaryGrainToCanonical: Affine2D?
    public let secondaryGrainToCanonical: Affine2D?
    public let reflected: Bool
}

public enum LogicalDabTransformer {
    public static func transform(
        batch: LogicalDabBatch,
        through isometries: [CompiledIsometry]
    ) -> [TransformedStampFrame]
}
```

- A batch rejects seed zero, mixed actual/predicted dabs, duplicate or
  noncontiguous ordinals, ordinal overflow, nonfinite bounds, and more than 512
  dabs. Nonempty dab provenance must match the explicit `isPredicted` flag.
  Empty batches retain that flag and the supplied zero-length ordinal range so
  samples that emit no dab remain ordered and replayable.
- Each dab's conservative bounds and the batch union come from all four
  transformed local tip corners plus declared material halo, not center ±
  radius; chisel/aspect/offset transforms must be enclosed.
- Transform composition is
  `dab.brushToWorld.concatenating(isometry.localToCanonical)`.
- Each present grain frame composes with the same isometry, preserving its
  canonical or brush-local anchoring selected by the definition.
- Isometry enumeration never consumes random values or rewrites the source
  logical dab.

- [ ] **Step 1: Write failing batch and symmetry-frame tests**

```swift
@Test
func rotationAndReflectionTransformTheWholeStampFrame() throws {
    let dab = LogicalDab.fixture(
        ordinal: 0,
        brushToWorld: Affine2D(
            xAxis: SIMD2(10, 0),
            yAxis: SIMD2(0, 4),
            translation: SIMD2(20, 30)
        )
    )
    let batch = try LogicalDabBatch(
        seed: 9,
        startingOrdinal: 0,
        isPredicted: false,
        dabs: [dab]
    )
    let frames = LogicalDabTransformer.transform(
        batch: batch,
        through: [
            CompiledIsometry(
                ordinal: 0,
                localToCanonical: .identity,
                operation: .identity
            ),
            CompiledIsometry(
                ordinal: 1,
                localToCanonical: reflectionAcrossYAxis,
                operation: CompiledGroupOperation(
                    rotationStep: 0,
                    rotationOrder: 1,
                    reflected: true
                )
            ),
        ]
    )

    #expect(frames.count == 2)
    #expect(frames[0].brushToCanonical.xAxis == SIMD2(10, 0))
    #expect(frames[1].brushToCanonical.xAxis == SIMD2(-10, 0))
    #expect(frames[1].reflected)
    #expect(batch.dabs == [dab])
}
```

- [ ] **Step 2: Run the focused test and observe missing types**

Run:

```bash
swift test --filter LogicalDabBatchTests
```

Expected: compilation fails because the batch/frame types are absent.

- [ ] **Step 3: Rename the domain type without breaking callers**

Rename the `DabAttributes` declaration to `LogicalDab` and add the public
typealias. Preserve all old stored fields and initializer argument order, then
append the new fully evaluated fields with an overload supplying exact neutral
compatibility values. The current renderer continues reading the old fields.
Add tests that bounds include rotated chisel corners and material halo, and
that the recorded random values stay identical across every projected copy.
Switch the characterizer from its Task 1 derived extension payload to these
stored values and assert every digest is unchanged.

- [ ] **Step 4: Add batch-returning generator methods**

Add transactional convenience APIs:

```swift
public mutating func beginBatch(
    _ sample: WorldStrokeSample
) -> LogicalDabBatch

public mutating func appendBatch(
    _ sample: WorldStrokeSample
) -> LogicalDabBatch

public mutating func finishBatch(
    _ sample: WorldStrokeSample
) -> LogicalDabBatch
```

They collect the existing callback output. If validation unexpectedly fails,
the generator remains unchanged. Capture `emittedDabCount` before evaluation
and pass it as `startingOrdinal`, including when no dab is emitted. Existing
callback APIs remain available for the current renderer until Task 11.

- [ ] **Step 5: Update transient replay to store `LogicalDab`**

Only names change in `TransientStrokeDab`; projected-instance counts and
promotion boundaries remain identical.

- [ ] **Step 6: Run batch, generator, replay, and symmetry tests**

Run:

```bash
swift test --filter LogicalDabBatchTests
swift test --filter BrushStrokeGeneratorTests
swift test --filter TransientStrokeBufferTests
swift test --filter SymmetryDescriptorCompilerTests
swift test --filter BrushCharacterization
```

Expected: all tests pass and characterization digests remain unchanged.

- [ ] **Step 7: Commit**

```bash
git add \
  Sources/PatternEngine/BrushModel/LogicalDabBatch.swift \
  Sources/PatternEngine/BrushDynamicsEngine.swift \
  Sources/PatternEngine/BrushStrokeGenerator.swift \
  Sources/PatternEngine/TransientStrokeBuffer.swift \
  Sources/PatternEngine/Verification/BrushCharacterization.swift \
  Tests/PatternEngineTests/LogicalDabBatchTests.swift \
  Tests/PatternEngineTests/TransientStrokeBufferTests.swift \
  Tests/PatternEngineTests/BrushCharacterizationTests.swift
git commit -m "feat(brush): add logical dab batches"
```

---

### Task 7: Add The Versioned `.layabrush` Package

**Files:**

- Create: `Sources/BrushFormat/BrushPackageManifest.swift`
- Create: `Sources/BrushFormat/BrushPackage.swift`
- Create: `Sources/BrushFormat/BrushPackageCodec.swift`
- Create: `Sources/BrushFormat/BrushPackageIO.swift`
- Create: `Sources/BrushFormat/BrushContentHash.swift`
- Create: `Tests/BrushFormatTests/BrushPackageCodecTests.swift`
- Create: `Tests/BrushFormatTests/BrushPackageIOTests.swift`
- Create: `Tests/BrushFormatTests/Fixtures/shape-4x4.png`
- Modify: `Package.swift:8-82`

**Interfaces:**

```swift
public struct BrushPackageResource:
    Codable, Equatable, Sendable
{
    public let id: String
    public let kind: BrushResourceKind
    public let path: String
    public let mediaType: String
    public let sha256: String
    public let encodedByteCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
}

public struct BrushPackageManifest:
    Codable, Equatable, Sendable
{
    public static let currentVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let definitionPath: String
    public let resources: [BrushPackageResource]
}

public struct BrushPackage: Equatable, Sendable {
    public let manifest: BrushPackageManifest
    public let definition: BrushDefinition
    public let resourceData: [String: Data]
}

public enum BrushPackageCodec {
    public static func encode(_ package: BrushPackage) throws -> Data
    public static func decode(_ data: Data) throws -> BrushPackage
}

public enum BrushPackageIO {
    public static func save(
        _ package: BrushPackage,
        to destination: URL
    ) throws
    public static func load(from source: URL) throws -> BrushPackage
}
```

- Archive paths are exactly `manifest.json`, `definition.json`, and
  `resources/<content-hash>.<extension>`.
- Manifest and definition use sorted-key UTF-8 JSON with no nonfinite floats.
- Decoding ignores unknown JSON keys within a supported schema version and
  preserves string capability declarations. It rejects unsupported schema
  versions; Task 5/10 compilation rejects unknown required capabilities.
- SHA-256 is lowercase 64-character hex using CryptoKit.
- Limits: 64 entries, 64 MiB per encoded resource, 192 MiB expanded package,
  512-byte paths, 16 resources, and 8192 × 8192 declared image dimensions.
- Decode verifies archive safety, exact entry set, hashes, byte counts,
  unique IDs and paths, resource-reference consistency, and media types
  `image/png` or `image/tiff`. Required definition references must be present.
  An absent optional shape/grain reference is valid only with its declared
  fallback. Every manifest resource must be referenced by the definition or
  declared as its single optional preview.
- BrushFormat validates the declared dimensions against format limits. Task 9
  compares them with the actual dimensions read by ImageIO before allocation.
- Atomic save writes, reopens, validates, then replaces.

- [ ] **Step 1: Add BrushFormat targets and failing round-trip tests**

Add `BrushFormat` product/target depending on `PatternEngine` and
`SafeArchive`, plus `BrushFormatTests`.

```swift
@Test
func packageRoundTripsDeterministically() throws {
    let package = try BrushPackage.fixture(
        definition: .fixture(),
        resources: [
            ("shape.main", .shape, fixturePNGData),
        ]
    )
    let first = try BrushPackageCodec.encode(package)
    let second = try BrushPackageCodec.encode(package)
    #expect(first == second)
    #expect(try BrushPackageCodec.decode(first) == package)
}
```

- [ ] **Step 2: Run tests and verify missing module/API**

Run:

```bash
swift test --filter BrushFormatTests
```

Expected: build fails because `BrushFormat` source files are absent.

- [ ] **Step 3: Implement manifest and content hashing**

The fixture package's resource path must be derived from the SHA-256, not its
display ID:

```swift
let path = "resources/\(sha256).png"
```

Sort manifest resources by ID before encoding.

- [ ] **Step 4: Implement secure codec and atomic I/O**

Decode must reject these exact cases in parameterized tests:

- missing/duplicate manifest or definition;
- unreferenced extra archive entry;
- hash or byte-count mismatch;
- duplicate resource ID or path;
- unsafe path;
- unsupported schema/media type;
- definition referencing a missing or kind-mismatched resource;
- optional shape/grain resource missing its fallback;
- unreferenced manifest resource or multiple previews;
- entry/resource/expanded-size limit;
- interrupted replacement preserving the previous file.

- [ ] **Step 5: Run format, safe archive, and model tests**

Run:

```bash
swift test --no-parallel --filter BrushFormatTests
swift test --no-parallel --filter SafeArchiveTests
swift test --no-parallel --filter BrushDefinitionTests
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add \
  Package.swift \
  Sources/BrushFormat \
  Tests/BrushFormatTests
git commit -m "feat(brush): add native brush package"
```

---

### Task 8: Complete Pencil And Wacom Normalized Input

**Files:**

- Modify: `Package.swift:7-12`
- Modify: `App/project.yml:67-97`
- Modify: `Sources/PatternEngine/StrokeSample.swift:1-210`
- Modify: `Sources/PatternEngine/BrushInput.swift:8-130`
- Modify:
  `Sources/PatternEngine/CentripetalCatmullRomStrokeInterpolator.swift`
- Modify: `Sources/PatternEngine/StrokeStabilizer.swift:70-90`
- Modify: `Sources/PatternEngine/TransientStrokeBuffer.swift`
- Modify: `Sources/PatternEngine/BrushDynamicsEngine.swift`
- Modify: `App/PatternSpike/Input/BrushInputAdapter.swift:1-158`
- Modify: `App/PatternSpike/Canvas/InteractiveMetalView.swift`
- Modify: `App/PatternSpike/Canvas/MetalCanvas.swift:5-82`
- Modify: `Tests/PatternEngineTests/BrushInputTests.swift`
- Modify: `Tests/PatternEngineTests/AttributedStrokeInterpolatorTests.swift`
- Modify: `Tests/PatternEngineTests/TransientStrokeBufferTests.swift`
- Modify: `App/Tests/EditorSessionControllerTests.swift`

**Interfaces:**

Add:

```swift
public struct StrokeEstimatedProperties:
    OptionSet, Equatable, Hashable, Sendable
{
    public let rawValue: UInt8

    public static let pressure =
        StrokeEstimatedProperties(rawValue: 1 << 0)
    public static let azimuth =
        StrokeEstimatedProperties(rawValue: 1 << 1)
    public static let altitude =
        StrokeEstimatedProperties(rawValue: 1 << 2)
    public static let location =
        StrokeEstimatedProperties(rawValue: 1 << 3)
    public static let roll =
        StrokeEstimatedProperties(rawValue: 1 << 4)
}

public struct StrokeInputCapabilities {
    public static let tangentialPressure =
        StrokeInputCapabilities(rawValue: 1 << 4)
}

public struct StrokeSample {
    public let tangentialPressure: Float?
    public let deviceIdentifier: UInt64?
    public let estimationUpdateIndex: Int?
    public let estimatedProperties: StrokeEstimatedProperties
    public let estimatedPropertiesExpectingUpdates:
        StrokeEstimatedProperties
}

public struct WorldStrokeSample {
    public let tangentialPressure: Float?
    public let deviceIdentifier: UInt64?
    public let estimationUpdateIndex: Int?
    public let estimatedProperties: StrokeEstimatedProperties
    public let estimatedPropertiesExpectingUpdates:
        StrokeEstimatedProperties
}

public enum EstimatedStrokeUpdateTarget: Equatable, Sendable {
    case authoritative
    case predicted
}

public struct EstimatedStrokeUpdatePlan: Equatable, Sendable {
    public let target: EstimatedStrokeUpdateTarget
    public let sourceReplayEpoch: UInt64
    public let replacedChunkIndex: Int
    public let mergedSample: WorldStrokeSample
    public let generatorBeforeReplacement: BrushStrokeGenerator?
    public let samplesToReplay: [WorldStrokeSample]
}
```

- Tangential pressure normalizes to `-1...1`.
- `deviceIdentifier` records a nonnegative native tablet ID when one exists;
  Pencil and mouse may leave it absent. It is diagnostic/replay metadata and
  never participates in dynamics.
- `estimationUpdateIndex` must be nonnegative when present.
- `.estimatedUpdate` requires an update index. Actual, coalesced, and predicted
  samples may carry that same index while UIKit is waiting for estimated
  properties.
- Estimated/expecting flags must be subsets of the sample's input
  capabilities, except location, and `expectingUpdates` must be a subset of
  `estimatedProperties`.
- An estimated update replaces only a retained sample with the same index.
  For actual/coalesced input, rebuild the authoritative replay suffix from the
  generator snapshot immediately before the replaced sample. For predicted
  input, rebuild only the predicted suffix from the authoritative checkpoint.
  Never append the update as a new path point.
- macOS reads `NSEvent.capabilityMask`, `deviceID`, `pressure`, `tilt`,
  `rotation`, and `tangentialPressure` for tablet-point events. A sensor is
  present only when the event declares that capability. Preserve the existing
  tilt-to-altitude/azimuth conversion and degrees-to-radians barrel rotation.
- iPad reads `UITouch.force / maximumPossibleForce`, `altitudeAngle`,
  `azimuthAngle(in:)`, `rollAngle`, `estimationUpdateIndex`,
  `estimatedProperties`, `estimatedPropertiesExpectingUpdates`, coalesced
  touches, predicted touches, and estimated-property updates.
- Because unsupported Pencil hardware reports roll as zero, advertise `.roll`
  only after the touch's estimated-property flags include roll or a nonzero
  finite roll has been observed; retain that discovered capability for the
  active touch. Never infer a fake roll capability from API availability.
- iPad actual/coalesced samples precede predicted samples in stable timestamp
  order. Predicted samples never carry `.ended`.
- Canvas refresh follows the active screen's `maximumFramesPerSecond`;
  remove the fixed `60`.

- [ ] **Step 1: Write failing normalization and interpolation tests**

```swift
@Test
func tangentialPressureAndEstimationIdentitySurviveInterpolation() throws {
    let sample = try #require(StrokeSample.validated(
        position: ScreenPoint(x: 1, y: 2),
        pressure: 0.7,
        timestamp: 1,
        phase: .moved,
        source: .tablet,
        kind: .estimatedUpdate,
        capabilities: [.pressure, .tangentialPressure],
        tangentialPressure: 2,
        estimationUpdateIndex: 9
    ))
    var input = BrushInputDeriver()
    let world = input.derive(sample, viewport: .identityFixture)

    #expect(world.tangentialPressure == 1)
    #expect(world.estimationUpdateIndex == 9)
}
```

Add tests that negative estimation indices fail validation, actual samples can
carry a pending update index, `.estimatedUpdate` requires an index, and missing
tablet/Pencil fields stay `nil`. Add invalid estimated-property subset tests.

- [ ] **Step 2: Run pure tests to verify the fields are absent**

Run:

```bash
swift test --filter BrushInputTests
swift test --filter AttributedStrokeInterpolatorTests
```

Expected: compilation fails on the new fields/capability.

- [ ] **Step 3: Extend the platform-free sample path**

Propagate the new fields through validation, `WorldStrokeSample`,
`InterpolatedStrokeSample`, interpolation, stabilizer copies, and dynamics
input normalization. Device identity, estimated-property flags, and update
indices are discrete: choose the nearer endpoint during interpolation; do not
numerically interpolate them.

- [ ] **Step 4: Add deterministic estimated-update replay planning**

Add:

```swift
public func planEstimatedUpdate(
    _ update: WorldStrokeSample
) throws -> EstimatedStrokeUpdatePlan

public mutating func replaceEstimatedSuffix(
    using plan: EstimatedStrokeUpdatePlan,
    with rebuiltChunks: [TransientStrokeChunk]
) throws -> TransientStrokeBufferUpdate
```

`planEstimatedUpdate` requires exactly one retained match, identifies whether
it is authoritative or predicted, replaces only properties that the original
sample marked as expecting an update (`location` may replace position),
preserves timestamp, lifecycle, original actual/coalesced/predicted provenance,
source, update index, and device identity, adopts the update's remaining
estimated/expecting sets, and returns the merged sample, source replay epoch,
and matching later suffix for deterministic replay.
`replaceEstimatedSuffix` is transactional: authoritative replacement clears
prediction; predicted replacement changes only prediction. Either path
increments the epoch exactly once and rejects stale plans, target/index
mismatches, or capacity overflow without mutating the buffer.

An `.ended` sample with expected updates renders as transient preview but does
not commit. `EditorSessionController` finalizes exactly once after the last
expected property resolves. Cancellation discards it. If lifecycle teardown or
a new pointer begins first, finalize using the latest retained estimate, emit a
development diagnostic, and ignore subsequent late updates.

Tests must cover force-only, location-only, and multi-property replacement;
multiple updates for one index; replay from the preceding generator snapshot;
unknown/promoted indices; stale plans; capacity rollback; deferred end commit;
teardown fallback; and exactly one final transaction.

- [ ] **Step 5: Extend the macOS adapter**

Add `deviceIdentifier`, `tangentialPressure`, and capability-mask extraction to
`NativeSample` and `StrokeSample.validated`. Keep equal-timestamp delivery
stable.

- [ ] **Step 6: Add the iPad interactive MTKView and adapter branch**

Under `#if os(iOS)`, make an `InteractiveMetalView` subclass that forwards
`touchesBegan`, `touchesMoved`, `touchesEnded`, `touchesCancelled`, and
`touchesEstimatedPropertiesUpdated` to `EditorSessionController`.

For a moved Pencil touch:

```swift
let actualTouches = stableTimestampOrder(
    event.coalescedTouches(for: touch) ?? [touch]
)
let predicted = stableTimestampOrder(
    event.predictedTouches(for: touch) ?? []
)
let actual = actualTouches.enumerated().compactMap { index, sample in
    normalized(
        sample,
        kind: index == actualTouches.count - 1 ? .actual : .coalesced,
        phase: .moved
    )
}
let samples = actual + predicted.compactMap {
    normalized($0, kind: .predicted, phase: .moved)
}
controller.handleStrokeSamples(samples)
```

`stableTimestampOrder` sorts ascending by timestamp and retains the framework
array order for ties.

The final member of a began/ended batch receives the lifecycle phase; earlier
coalesced members use `.moved`. Cancellation sends one actual `.cancelled`
sample and clears local touch state.

- [ ] **Step 7: Raise only the iPad baseline**

Set:

```swift
// Package.swift
.iOS(.v18)
```

```yaml
# App/project.yml, PatternSpikePad
deploymentTarget: "18.0"
```

Regenerate:

```bash
./scripts/bootstrap.sh
```

- [ ] **Step 8: Run pure, app-controller, macOS, and iPad builds**

Run:

```bash
swift test --filter BrushInputTests
swift test --filter AttributedStrokeInterpolatorTests
swift test --filter TransientStrokeBufferTests
swift test --filter EditorSessionControllerTests
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -destination platform=macOS \
  -derivedDataPath .build/DerivedData \
  build CODE_SIGNING_ALLOWED=NO
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedDataPad \
  build CODE_SIGNING_ALLOWED=NO
```

Expected: all tests and both builds pass.

- [ ] **Step 9: Commit**

```bash
git add \
  Package.swift \
  App/project.yml \
  App/PatternSpike.xcodeproj \
  Sources/PatternEngine/StrokeSample.swift \
  Sources/PatternEngine/BrushInput.swift \
  Sources/PatternEngine/CentripetalCatmullRomStrokeInterpolator.swift \
  Sources/PatternEngine/StrokeStabilizer.swift \
  Sources/PatternEngine/TransientStrokeBuffer.swift \
  Sources/PatternEngine/BrushDynamicsEngine.swift \
  App/PatternSpike/Input/BrushInputAdapter.swift \
  App/PatternSpike/Canvas/InteractiveMetalView.swift \
  App/PatternSpike/Canvas/MetalCanvas.swift \
  Tests/PatternEngineTests/BrushInputTests.swift \
  Tests/PatternEngineTests/AttributedStrokeInterpolatorTests.swift \
  Tests/PatternEngineTests/TransientStrokeBufferTests.swift \
  App/Tests/EditorSessionControllerTests.swift
git commit -m "feat(input): complete Pencil and tablet samples"
```

---

### Task 9: Decode And Prepare Large Brush Textures Off The Input Path

**Files:**

- Create:
  `Sources/MetalRenderer/BrushCompiler/BrushDeviceProfile.swift`
- Create:
  `Sources/MetalRenderer/BrushCompiler/BrushCompilationReport.swift`
- Create:
  `Sources/MetalRenderer/BrushCompiler/DecodedBrushTexture.swift`
- Create:
  `Sources/MetalRenderer/BrushCompiler/BrushAssetDecoder.swift`
- Create:
  `Tests/MetalRendererTests/BrushAssetDecoderTests.swift`
- Create:
  `Tests/MetalRendererTests/BrushDeviceProfileTests.swift`
- Modify: `Package.swift`

**Interfaces:**

```swift
public enum BrushPerformanceTier:
    String, Codable, Equatable, Sendable
{
    case realtime120
    case realtime60
    case unsupportedResourceCost
}

public enum BrushPerformanceEvidenceBasis:
    String, Codable, Equatable, Sendable
{
    case estimated
    case measured
}

public struct BrushPerformanceClassification:
    Codable, Equatable, Sendable
{
    public let tier: BrushPerformanceTier
    public let basis: BrushPerformanceEvidenceBasis
    public let reason: String
}

public enum BrushCompatibilityLevel:
    String, Codable, Equatable, Sendable
{
    case exact
    case approximated
    case unsupported
}

public struct BrushCompatibilityEntry:
    Codable, Equatable, Sendable
{
    public let semanticKey: String
    public let level: BrushCompatibilityLevel
    public let message: String
}

public struct BrushCompilationReport: Codable, Equatable, Sendable {
    public let definitionID: String
    public let packageContentHash: String
    public let backend: BrushBackendKind
    public let compatibility: [BrushCompatibilityEntry]
    public let performance: BrushPerformanceClassification
    public let encodedResourceBytes: Int
    public let residentResourceBytes: Int
    public let deviceRegistryID: UInt64
}

public enum BrushCompilationStage:
    String, Codable, Equatable, Sendable
{
    case definition
    case archive
    case imageDecode
    case mipGeneration
    case textureUpload
    case residency
    case pipelineSelection
    case activation
}

public struct BrushCompilationFailure:
    Error, Codable, Equatable, Sendable
{
    public let definitionID: String
    public let packageContentHash: String
    public let backend: BrushBackendKind
    public let stage: BrushCompilationStage
    public let resourceID: String?
    public let requestedBytes: Int?
    public let deviceRegistryID: UInt64
    public let reason: String
}

public struct BrushDeviceProfile: Equatable, Sendable {
    public let registryID: UInt64
    public let recommendedWorkingSetBytes: UInt64
    public let maximumWorkingTextureDimension: Int
    public let brushCacheBudgetBytes: Int
    public let targetFramesPerSecond: Int
}

public struct DecodedBrushTexture: Equatable, Sendable {
    public let resourceID: String
    public let kind: BrushResourceKind
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let workingWidth: Int
    public let workingHeight: Int
    public let mipLevels: [Data]
    public let residentByteCount: Int
    public let wasResampled: Bool
}

public enum BrushAssetDecoder {
    public static func decode(
        resource: BrushPackageResource,
        data: Data,
        profile: BrushDeviceProfile
    ) throws -> DecodedBrushTexture
}
```

- Add `BrushFormat` as a `MetalRenderer` dependency.
- Portable working ceiling is 4096 × 4096 R8. This supplies at least two
  source texels for the current maximum 2000-pixel canonical brush diameter.
- Preserve aspect ratio; never upscale.
- Convert shape/grain assets to linear R8 coverage.
- Generate every mip on CPU with deterministic box averaging and defined
  integer rounding `(sum + sampleCount / 2) / sampleCount`.
- `residentByteCount` is the exact sum of mip byte counts.
- Default cache budget is:

```swift
min(
    256 * 1_024 * 1_024,
    max(
        64 * 1_024 * 1_024,
        Int(recommendedWorkingSetBytes / 10)
    )
)
```

- Resource decode rejects malformed images, zero dimensions, decompression
  beyond 8192 × 8192, kind mismatch, unsupported media type, and decoded byte
  overflow.
- Actual ImageIO dimensions must equal the manifest's declared
  `pixelWidth`/`pixelHeight`; a mismatch fails before pixel allocation.
- Compatibility entries are sorted by semantic key and unique. Unsupported
  required semantics fail compilation; approximations remain explicit and
  never silently become exact.
- Failures carry hashes, identifiers, stage, resource cost, backend, and
  device profile but never embed third-party texture bytes.

- [ ] **Step 1: Write failing decode, mip, resample, and budget tests**

```swift
@Test
func decoderBuildsDeterministicR8MipPyramid() throws {
    let decoded = try BrushAssetDecoder.decode(
        resource: .fixturePNG,
        data: fixturePNGData,
        profile: .testing(maximumWorkingTextureDimension: 4)
    )
    #expect(decoded.workingWidth == 4)
    #expect(decoded.workingHeight == 4)
    #expect(decoded.mipLevels.map(\.count) == [16, 4, 1])
    #expect(decoded.residentByteCount == 21)
    #expect(!decoded.wasResampled)
}
```

Add a generated 8 × 4 fixture and assert a profile ceiling of 4 produces
4 × 2 and `wasResampled == true`. Add failures for a manifest/image dimension
mismatch, allocation overflow, and a compatibility report with duplicate or
unsorted semantic keys.

- [ ] **Step 2: Run tests and observe missing compiler types**

Run:

```bash
swift test --filter BrushAssetDecoderTests
swift test --filter BrushDeviceProfileTests
```

Expected: compilation fails because the decoder/profile types are absent.

- [ ] **Step 3: Implement bounded ImageIO decode**

Read dimensions from image properties before allocation. Reject dimensions
above 8192 or multiplication overflow. Draw into an 8-bit grayscale
`CGContext` with interpolation quality `.high` only when resampling; retain
exact source pixels when already R8-compatible.

- [ ] **Step 4: Implement deterministic mips and resource report**

Return a compilation diagnostic:

```swift
public enum BrushCompilationDiagnostic: Equatable, Sendable {
    case resourceResampled(
        id: String,
        sourceWidth: Int,
        sourceHeight: Int,
        workingWidth: Int,
        workingHeight: Int
    )
}
```

No diagnostic is emitted for an exact decode.

- [ ] **Step 5: Run decoder, format, and existing texture suites**

Run:

```bash
swift test --filter BrushAssetDecoderTests
swift test --filter BrushDeviceProfileTests
swift test --filter BrushFormatTests
swift test --filter BrushTextureTests
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add \
  Package.swift \
  Sources/MetalRenderer/BrushCompiler \
  Tests/MetalRendererTests/BrushAssetDecoderTests.swift \
  Tests/MetalRendererTests/BrushDeviceProfileTests.swift
git commit -m "feat(brush): prepare bounded texture pyramids"
```

---

### Task 10: Add Private GPU Upload, LRU Residency, And Async Compilation

**Files:**

- Create:
  `Sources/MetalRenderer/BrushCompiler/BrushTextureUploader.swift`
- Create:
  `Sources/MetalRenderer/BrushCompiler/BrushResourceResidency.swift`
- Create:
  `Sources/MetalRenderer/BrushCompiler/BrushResourceCache.swift`
- Create:
  `Sources/MetalRenderer/BrushCompiler/CompiledBrush.swift`
- Create:
  `Sources/MetalRenderer/BrushCompiler/BrushCompiler.swift`
- Create:
  `Tests/MetalRendererTests/BrushResourceResidencyTests.swift`
- Create:
  `Tests/MetalRendererTests/BrushCompilerTests.swift`

**Interfaces:**

```swift
public struct BrushFunctionConstants: Equatable, Hashable, Sendable {
    public let usesSecondaryShape: Bool
    public let usesGrain: Bool
    public let usesSecondaryGrain: Bool
    public let usesDestinationSampling: Bool
}

public struct BrushPipelineKey: Hashable, Sendable {
    public let backend: BrushBackendKind
    public let accumulation: BrushAccumulationMode
    public let edgeTreatment: BrushEdgeTreatment
    public let functionConstants: BrushFunctionConstants
}

public struct BrushUniformTemplate: Equatable, Sendable {
    public let placement: BrushPlacementDefinition
    public let coverage: BrushCoverageDefinition
    public let color: BrushColorBehaviorDefinition
    public let material: BrushMaterialDefinition
}

public enum BrushResourcePressureResult: Equatable, Sendable {
    case satisfied(evictedKeys: [String])
    case activeBrushExceedsTarget(requiredBytes: Int, targetBytes: Int)
}

struct BrushResourceResidency: Equatable, Sendable {
    mutating func access(
        key: String,
        byteCount: Int,
        pinned: Bool
    ) throws -> [String]
    mutating func pin(_ key: String)
    mutating func unpin(_ key: String)
    mutating func remove(_ key: String)
}

@MainActor
public final class CompiledBrush {
    public let program: BrushProgram
    public let pipelineKey: BrushPipelineKey
    public let uniformTemplate: BrushUniformTemplate
    public let textures: [String: any MTLTexture]
    public let residentByteCount: Int
    public let report: BrushCompilationReport
}

@MainActor
public final class BrushCompiler {
    public private(set) var activeBrush: CompiledBrush?

    public init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        profile: BrushDeviceProfile
    )

    public func compileAndActivate(
        package: BrushPackage
    ) async throws -> CompiledBrush

    public func handleMemoryPressure(
        targetResidentBytes: Int
    ) -> BrushResourcePressureResult
}
```

- Decode and CPU mip generation run in a detached `userInitiated` task with a
  Sendable package copy.
- Check cancellation before decode, between resources, before GPU allocation,
  after each awaited blit completion, and before the cache transaction.
  Cancellation releases candidates and leaves the previous active brush and
  cache pinning unchanged.
- GPU creation happens only after decode completes.
- Working textures are `.r8Unorm`, `.private`, `.shaderRead`, mipmapped.
- Upload uses a shared staging buffer plus blit copies; completion is awaited
  without blocking the main actor.
- Cache keys include resource SHA-256, working dimensions, pixel format, and
  mip policy.
- The effective texture ceiling is the minimum of the portable 4096 ceiling,
  device profile, and definition limit. The effective brush residency ceiling
  is the minimum of the cache budget and definition limit.
- The active compiled brush is pinned. Insertion evicts least-recently-used,
  unpinned entries until within budget. Insertion fails atomically when pinned
  bytes plus the candidate exceed the budget.
- Failed compilation leaves the previous active brush pinned and unchanged.
- Memory pressure evicts inactive least-recently-used resources first. It never
  tears down an active brush mid-stroke; if the target is below pinned active
  bytes, it returns `activeBrushExceedsTarget` so the next stroke can be
  blocked with an explicit reason.
- Missing optional shape/grain data resolves only through its declared
  built-in fallback and records an approximation entry. Missing required data,
  an unsupported required semantic, or a requested canvas-interaction backend
  fails before activation during Stage 2.
- Derive the immutable pipeline key, function constants, and uniform template
  during compilation. No stroke path constructs or mutates them.
- Estimated performance tier:
  - deposition, no dual layers, at most one shape plus one grain working
    texture, resident bytes at most 64 MiB, and definition intent
    `realtime120` on a profile targeting at least 120 FPS -> `realtime120`;
  - any other supported deposition program inside its effective cache budget
    -> `realtime60`;
  - candidate above cache budget -> `unsupportedResourceCost`.
  Mark the basis `.estimated`; no hardware measurement claim is made.

- [ ] **Step 1: Write failing pure residency tests**

```swift
@Test
func insertionEvictsOnlyLeastRecentlyUsedUnpinnedEntries() throws {
    var state = BrushResourceResidency(byteBudget: 100)
    #expect(try state.access(key: "active", byteCount: 60, pinned: true) == [])
    #expect(try state.access(key: "old", byteCount: 30, pinned: false) == [])
    #expect(try state.access(key: "new", byteCount: 30, pinned: false) == ["old"])
    #expect(state.keys == ["active", "new"])
    #expect(state.residentByteCount == 90)
}
```

Add tests for duplicate access refreshing recency, byte-count mismatch,
integer overflow, pinned candidate failure, and atomic state on failure.

- [ ] **Step 2: Write failing Metal compiler tests**

With a real Metal device, compile and activate the 4 × 4 fixture and assert:

```swift
#expect(compiled.textures["shape.main"]?.storageMode == .private)
#expect(compiled.textures["shape.main"]?.mipmapLevelCount == 3)
#expect(compiled.residentByteCount == 21)
#expect(compiled.report.performance.basis == .estimated)
#expect(compiled.pipelineKey.backend == .deposition)
#expect(!compiled.pipelineKey.functionConstants.usesDestinationSampling)
```

Read back each mip through a blit buffer and compare with
`DecodedBrushTexture.mipLevels`. Add transactional tests for cancellation at
each injectable phase, missing required data, explicit optional fallback,
unsupported canvas interaction, pipeline/uniform derivation, inactive-only
memory-pressure eviction, and the active-brush pressure result. Every failure
asserts its exact `BrushCompilationStage` and redacted context.

- [ ] **Step 3: Run focused tests and observe missing APIs**

Run:

```bash
swift test --filter BrushResourceResidencyTests
swift test --filter BrushCompilerTests
```

Expected: compilation fails because residency/compiler types are absent.

- [ ] **Step 4: Implement pure residency before Metal ownership**

Use a monotonic `UInt64` access ordinal and a dictionary of:

```swift
struct Entry {
    let byteCount: Int
    var pinned: Bool
    var lastAccess: UInt64
}
```

Choose evictions by `(lastAccess, key)` for deterministic ties.

- [ ] **Step 5: Implement upload, cache, and compiler transaction**

Build all program/resource candidates first. Insert into cache and switch the
active key only after every upload succeeds. On error, release candidates and
leave cache pinning and active brush unchanged.

- [ ] **Step 6: Prove compilation is not performed during a stroke**

Expose debug counters:

```swift
public struct BrushCompilerCounters: Equatable, Sendable {
    public let packageDecodeCount: UInt64
    public let imageDecodeCount: UInt64
    public let textureUploadCount: UInt64
    public let cacheHitCount: UInt64
}
```

In tests, compile once, render/generate 1,000 logical dabs through the program,
and assert counters do not change.

- [ ] **Step 7: Run compiler, residency, and full Metal unit tests**

Run:

```bash
swift test --filter BrushResourceResidencyTests
swift test --filter BrushCompilerTests
swift test --no-parallel --filter MetalRendererTests
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add \
  Sources/MetalRenderer/BrushCompiler \
  Tests/MetalRendererTests/BrushResourceResidencyTests.swift \
  Tests/MetalRendererTests/BrushCompilerTests.swift
git commit -m "feat(brush): compile and cache GPU resources"
```

---

### Task 11: Route Existing Anchors Through The Compiled Foundation

**Files:**

- Modify: `Sources/EditorCore/Brushes/AnchorBrushCatalog.swift:8-238`
- Modify: `Sources/EditorCore/Transactions/EditorTransaction.swift:28-100`
- Modify: `Sources/EditorCore/Model/EditorModel.swift:6-100`
- Modify: `Sources/PatternEngine/StrokeRenderStyle.swift`
- Modify: `Sources/MetalRenderer/Brush/BrushMaterialState.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift:111-145,560-620,1380-1430`
- Modify: `App/PatternSpike/EditorSessionController.swift:120-205`
- Modify: `Tests/EditorCoreTests/AnchorBrushCatalogTests.swift`
- Modify: `Tests/EditorCoreTests/EditorTransactionTests.swift`
- Modify: `Tests/MetalRendererTests/RendererTransactionTests.swift`
- Modify: `App/Tests/EditorSessionControllerTests.swift`

**Interfaces:**

`AnchorBrushEntry` becomes:

```swift
public struct AnchorBrushEntry: Equatable, Sendable {
    public let displayName: String
    public let role: AnchorBrushRole
    public let definition: BrushDefinition
    public let program: BrushProgram

    public var id: BrushRecipeID { definition.id }
    public var compatibilityRecipe: BrushRecipe {
        guard let recipe = program.compatibilityRecipe else {
            preconditionFailure(
                "Built-in anchor must remain legacy-compatible"
            )
        }
        return recipe
    }
}
```

- Build definitions and programs once in static catalog initialization.
- `DrawingTransaction` and `StrokeRenderStyle` capture `BrushProgram`, not a
  mutable definition and not a newly compiled recipe.
- `GridRenderer` constructs `BrushStrokeGenerator(program:...)`.
- `GridRenderer` applies `EstimatedStrokeUpdatePlan` to the retained transient
  suffix. A late or unknown update is ignored with a development diagnostic;
  it never enters canonical output as a new point.
- Current texture/material lookup reads the compatibility values from
  `program`; it does not invoke package decode or the Metal `BrushCompiler`.
- The production pointer-down path contains no
  `LegacyBrushRecipeAdapter.definition`, `BrushProgramCompiler.compile`,
  archive read, image decode, or texture upload.

- [ ] **Step 1: Write failing catalog and transaction tests**

```swift
@Test
func anchorProgramsArePrecompiledAndLegacyExact() throws {
    for entry in AnchorBrushCatalog.all {
        #expect(entry.program.definition == entry.definition)
        #expect(
            try LegacyBrushRecipeAdapter.recipe(from: entry.definition)
                == entry.compatibilityRecipe
        )
    }
}

@Test
func pointerDownCapturesProgramForWholeTransaction() throws {
    var transaction = EditorTransaction()
    let first = AnchorBrushCatalog.technicalInk.program
    let second = AnchorBrushCatalog.dryPencil.program

    _ = transaction.reduce(.pointerBegan(.fixtureBegan, program: first))
    _ = transaction.reduce(.recipeIntent(second.definition.id))

    #expect(transaction.drawing?.program == first)
}
```

- [ ] **Step 2: Run focused tests and observe API mismatches**

Run:

```bash
swift test --filter AnchorBrushCatalogTests
swift test --filter EditorTransactionTests
```

Expected: compilation fails because entries and transactions still expose
recipes.

- [ ] **Step 3: Migrate catalog and EditorCore ownership**

Keep user-visible recipe IDs and selection behavior unchanged. Rename
`selectedRecipe` only if every app binding is updated in the same commit; do
not leave duplicate selected recipe/program sources of truth.

- [ ] **Step 4: Migrate renderer stroke creation**

At pointer-down, capture the selected `BrushProgram` in `StrokeRenderStyle`.
Use it for generator, material, shape/grain descriptors, replay contract, and
commit. Do not consult `EditorModel` again during the stroke.

- [ ] **Step 5: Prove old and new paths are identical**

Run the Task 1 characterization matrix and Task 2 offscreen baseline. Add a
test that directly compares generated `LogicalDabBatch` arrays from the
program path with the compatibility recipe path for all 15 trace/anchor pairs.

- [ ] **Step 6: Run transaction, renderer, harness, and app tests**

Run:

```bash
swift test --filter AnchorBrushCatalogTests
swift test --filter EditorTransactionTests
swift test --filter RendererTransactionTests
swift test --filter EditorSessionControllerTests
swift test --filter BrushCharacterization
swift test --no-parallel --filter SliceFourHarnessRunnerTests
```

Expected: all tests pass and the checked-in baseline is unchanged.

- [ ] **Step 7: Commit**

```bash
git add \
  Sources/EditorCore/Brushes/AnchorBrushCatalog.swift \
  Sources/EditorCore/Transactions/EditorTransaction.swift \
  Sources/EditorCore/Model/EditorModel.swift \
  Sources/PatternEngine/StrokeRenderStyle.swift \
  Sources/MetalRenderer/Brush/BrushMaterialState.swift \
  Sources/MetalRenderer/GridRenderer.swift \
  App/PatternSpike/EditorSessionController.swift \
  Tests/EditorCoreTests/AnchorBrushCatalogTests.swift \
  Tests/EditorCoreTests/EditorTransactionTests.swift \
  Tests/MetalRendererTests/RendererTransactionTests.swift \
  App/Tests/EditorSessionControllerTests.swift
git commit -m "refactor(brush): route anchors through programs"
```

---

### Task 12: Add The Foundation Gate And Record Evidence

**Files:**

- Create:
  `Sources/MetalRenderer/Capture/BrushFoundationEvidenceValidator.swift`
- Create:
  `Sources/BrushFoundationEvidenceGate/main.swift`
- Create:
  `Tests/MetalRendererTests/BrushFoundationEvidenceGateTests.swift`
- Create:
  `scripts/verify-brush-foundation.sh`
- Create:
  `docs/superpowers/milestones/10-world-class-brush-engine-foundation.md`
- Modify: `Package.swift`
- Modify:
  `docs/superpowers/specs/2026-07-26-world-class-brush-engine-design.md`

**Interfaces:**

- `BrushFoundationEvidenceGate LOGICAL_BASELINE RENDERER_BASELINE
  ARTIFACT_ROOT COMMIT` validates:
  source commit, all 15 logical baseline records, all eight renderer
  characterization records, logical/canonical digests, schema-6 benchmark
  fields, exact anchor adapter parity, resource-cache counters, and no missing
  positive/negative Slice 4 evidence.
- Exit `0` for correctness plus accepted stable performance, `2` only for the
  existing explicitly recognized paravirtual performance-pending condition,
  and `1` for every correctness/provenance failure.
- All validation logic lives in
  `MetalRenderer.BrushFoundationEvidenceValidator`; the executable is a thin
  argument/exit-code wrapper so the tests exercise the production validator.

- [ ] **Step 1: Write failing validator tests**

Add tests under
`Tests/MetalRendererTests/BrushFoundationEvidenceGateTests.swift` for:

- valid matrix;
- missing or changed 15-record logical baseline;
- missing characterization file;
- wrong commit;
- changed logical digest;
- changed canonical digest;
- missing compiler counters;
- positive scene missing;
- negative control unexpectedly succeeding;
- unrecognized performance-pending text.

Each corrupt case must fail independently.

- [ ] **Step 2: Run the validator tests and observe missing target/API**

Run:

```bash
swift test --filter BrushFoundationEvidenceGateTests
```

Expected: compilation fails because the gate target and validator are absent.

- [ ] **Step 3: Implement the executable and verification script**

The script must:

1. require committed, clean build inputs;
2. record `git rev-parse HEAD`;
3. run `swift test --no-parallel`;
4. run `./scripts/bootstrap.sh`;
5. build and analyze `PatternSpikeMac`;
6. build and analyze `PatternSpikePad` for generic iOS Simulator;
7. run all eight positive and negative Slice 4 scenes;
8. compare logical and renderer characterization files with both checked-in
   baselines;
9. build and run `BrushFoundationEvidenceGate`;
10. write source, OS, GPU, hardware, and toolchain provenance;
11. recheck HEAD and working-tree cleanliness at the terminal boundary.

- [ ] **Step 4: Run the full gate from a clean evidence commit**

First commit the gate implementation:

```bash
git add \
  Package.swift \
  Sources/MetalRenderer/Capture/BrushFoundationEvidenceValidator.swift \
  Sources/BrushFoundationEvidenceGate \
  Tests/MetalRendererTests/BrushFoundationEvidenceGateTests.swift \
  scripts/verify-brush-foundation.sh
git commit -m "test(brush): add foundation evidence gate"
```

Then run:

```bash
./scripts/verify-brush-foundation.sh
```

Expected terminal line:

```text
BRUSH FOUNDATION PASS artifacts=<absolute-path> commit=<40-hex-commit>
```

An exit `2` is recorded as performance pending, not passing. Any nonzero
correctness result blocks completion.

- [ ] **Step 5: Record the milestone without claiming hardware-only results**

Write exact commands, commit, tool versions, test counts, artifact paths,
baseline digest matrix, build results, and performance status in the milestone.
Mark Pencil/Wacom feel, true input-to-photon latency, ProMotion stability,
thermal behavior, and memory-warning recovery as hardware gates unless they
were actually measured.

- [ ] **Step 6: Re-run documentation and source integrity checks**

Run:

```bash
incomplete_pattern='T''BD|T''ODO|F''IXME|P''LACEHOLDER'
rg -n -i "$incomplete_pattern" \
  docs/superpowers/milestones/10-world-class-brush-engine-foundation.md
git diff --check
./scripts/verify-brush-foundation.sh
```

Expected: incomplete-marker search returns no matches, `git diff --check` is
clean, and the full gate repeats its accepted result.

- [ ] **Step 7: Commit the verified milestone**

```bash
git add \
  docs/superpowers/milestones/10-world-class-brush-engine-foundation.md \
  docs/superpowers/specs/2026-07-26-world-class-brush-engine-design.md
git commit -m "docs(brush): record foundation evidence"
```

---

## Completion Boundary

This plan is complete only when:

- the current renderer's logical and canonical outputs are characterized and
  pinned;
- native brush definitions round-trip through `.layabrush`;
- all current anchors adapt and compile exactly;
- actual/coalesced/predicted/estimated-update semantics include Pencil and
  Wacom capabilities;
- large assets decode and mip off the input path;
- compiled private GPU resources are bounded by a tested pinned-LRU policy;
- existing anchors use precompiled pure programs before pointer-down;
- Slice 4 output and every pre-existing invariant remain green;
- the evidence gate records an honest pass or explicitly pending hardware
  performance state.

Stage 3 Procreate conversion and Brush Lab work begins only in its own approved
plan after this boundary.
