# Compiled Symmetry Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the seven legacy tiling-specific production switches with a
validated compiled-symmetry foundation while preserving their persisted IDs,
CPU geometry, canonical raster bytes, shader output, and real-Metal evidence
exactly.

**Governing spec:**
`docs/superpowers/specs/2026-07-23-compiled-periodic-radial-symmetry-design.md`

**Architecture:** A stable `SymmetryPresetID` and `PatternSize` compile on the
cold path into one closed `CompiledSymmetry` value. The rectangular family
kernel consumes that value for cell enumeration, point folding, image
generation, and projection deduplication. Metal receives an append-only family
selector plus the unchanged legacy preset wire value. The independent oracle
continues to switch directly on the stable preset selector and never consumes
production descriptors.

**Tech Stack:** Swift 6, Swift Testing, Foundation, simd, Metal/MSL, shared
C/MSL ABI, XcodeGen, Bash, and the existing macOS real-Metal harness.

## Global Constraints

- Work directly on `main`; the user explicitly selected the main checkout.
- Preserve unrelated modified files and the untracked `.vscode/` directory.
  Stage only the files named by the current task.
- Phase 1 adds no user-facing tiling choice and does not change app controls.
- Preserve the exact legacy wire values `0...6`, Codable representation, case
  names, source spelling through a compatibility alias, and harness schema.
- New preset and ABI values are append-only. Do not renumber an existing
  selector, buffer index, texture index, or struct field.
- Preserve every existing `TilingStrategy` precondition message and half-open
  boundary behavior. Descriptor validation is typed; the compatibility facade
  retains the old trapping contract.
- The compiler runs only when a strategy/configuration is constructed. Stroke
  projection and fragment loops receive an already-compiled value.
- Production may consume compiled images and programs. The independent oracle
  may share `PatternSize`, `PixelSize`, affine primitives, and
  `SymmetryPresetID` only.
- Canonical pixels remain the retained document source of truth. Periodic
  preset changes remain metadata-only and never rewrite pixels.
- World interpolation remains before symmetry projection.
- The seven legacy modes must remain byte-for-byte compatible, not merely
  visually similar.
- The Phase 1 rectangular compiler must reject invalid dimensions before
  producing any partial descriptor.
- Do not add square, triangular, or radial behavior in this phase. Their public
  selectors, ownership polygons, raster metrics, and user controls belong to
  later plans.
- Do not introduce a CPU production renderer or feed production descriptors
  into the verification oracle.
- Run the focused test named in each step before moving on. Run the full Swift
  suite and both application builds before the phase is called complete.
- Obtain a fresh diff review and verification before every commit. Use small
  conventional commits and stage only task-owned paths.

## Phase Boundary

This plan implements delivery-sequence Phase 1 from the governing spec:

- stable preset and document-domain identifiers;
- a closed compiled descriptor and typed validation;
- a descriptor-driven rectangular family kernel;
- all seven current modes expressed by compiled data;
- descriptor-driven projection and Metal dispatch seams;
- independent-oracle, byte, shader, and real-Metal parity.

The following remain explicitly outside this plan:

- Phase 2: `p4`, `p4m`, square ownership domains, and square UI presets;
- Phase 3: triangular lattice, `p3`, `p6`, `p3m1`, `p6m`, and rectangular
  triangular supercell export;
- Phase 4: finite/radial documents, `C_n`, `D_n`, ray presets, locking, and
  sector storage;
- Phase 5: persistence migration for new modes, the expanded export matrix,
  and final product acceptance.

## Baseline Commands

Run these before Task 1 and paste the command results into the Phase 1
milestone draft created in Task 6:

```bash
git status --short --branch
swift test --no-parallel
./scripts/bootstrap.sh
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  build CODE_SIGNING_ALLOWED=NO
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedDataPad \
  build CODE_SIGNING_ALLOWED=NO
```

Expected result: all tests and both builds pass. Record any pre-existing
failure without changing unrelated files. Existing slice verification scripts
have deliberate clean-source provenance checks, so do not run them against a
dirty user checkout and misreport that expected provenance rejection as a
product failure.

Before editing production code, also run the direct real-Metal matrix command
from Task 5.5 with this artifact root:

```bash
artifacts=".build/symmetry-phase1-legacy-baseline"
```

Then capture only deterministic PNG payloads, excluding benchmark JSON whose
provenance intentionally changes with the commit:

```bash
(
  cd .build/symmetry-phase1-legacy-baseline/positive
  find . -type f -name '*.png' -print0 \
    | sort -z \
    | xargs -0 shasum -a 256
) >.build/symmetry-phase1-legacy-baseline.sha256
test -s .build/symmetry-phase1-legacy-baseline.sha256
```

This pre-refactor manifest is the byte-for-byte legacy fixture for Task 5.
Keep it under ignored `.build/`; do not add generated artifacts to Git.

## Public Type Contract

Phase 1 converges on these names. Later phases extend their closed payloads;
they do not replace the selector or create a second production descriptor.

```swift
public enum SymmetryDocumentDomainID: UInt32, Codable, Sendable {
    case periodic = 0
    case finite = 1
}

public enum SymmetryPresetID: UInt32, CaseIterable, Codable, Sendable {
    case grid = 0
    case halfDrop = 1
    case brick = 2
    case mirrorX = 3
    case mirrorY = 4
    case mirrorXY = 5
    case rotational = 6
}

public typealias TilingKind = SymmetryPresetID

public enum SymmetryKernelFamily: UInt32, Codable, Sendable {
    case rectangular = 0
    case triangular = 1
    case radial = 2
}

public struct CompiledSymmetry: Equatable, Sendable {
    public let presetID: SymmetryPresetID
    public let domain: CompiledSymmetryDomain
    public let family: SymmetryKernelFamily
    public let images: [CompiledIsometry]
    public let ownership: CompiledOwnership
    public let displayProgram: CompiledDisplayProgram
    public let rasterMetric: RasterMetric2D
    public let exportCapability: SymmetryExportCapability
    public let cost: SymmetryCostBound
}
```

`CompiledSymmetry` is a validated runtime value. It is neither Codable nor a
user-authored program. Only `SymmetryPresetID` and document configuration are
serialized.

---

## Task 1: Pin Stable IDs and Compile the Seven Legacy Descriptors

**Files:**

- Modify: `Sources/PatternEngine/TilingKind.swift`
- Create: `Sources/PatternEngine/CompiledSymmetry.swift`
- Create: `Sources/PatternEngine/SymmetryDescriptorCompiler.swift`
- Create:
  `Tests/PatternEngineTests/SymmetryDescriptorCompilerTests.swift`

### 1.1 Write failing selector and descriptor tests

- [ ] Add
  `Tests/PatternEngineTests/SymmetryDescriptorCompilerTests.swift`.

The test suite must pin:

```swift
import Foundation
@testable import PatternEngine
import simd
import Testing

@Suite("Symmetry descriptor compiler")
struct SymmetryDescriptorCompilerTests {
    @Test
    func stableSelectorsAreAppendOnlyAndLegacyCompatible() throws {
        #expect(SymmetryDocumentDomainID.periodic.rawValue == 0)
        #expect(SymmetryDocumentDomainID.finite.rawValue == 1)
        #expect(SymmetryKernelFamily.rectangular.rawValue == 0)
        #expect(SymmetryKernelFamily.triangular.rawValue == 1)
        #expect(SymmetryKernelFamily.radial.rawValue == 2)
        #expect(SymmetryPresetID.allCases.map(\.rawValue) == Array(0...6))
        #expect(TilingKind.rotational.rawValue == 6)

        let encoded = try JSONEncoder().encode(SymmetryPresetID.mirrorXY)
        #expect(String(decoding: encoded, as: UTF8.self) == "5")
        #expect(
            try JSONDecoder().decode(
                SymmetryPresetID.self,
                from: Data("5".utf8)
            ) == .mirrorXY
        )
    }

    @Test(arguments: SymmetryPresetID.allCases)
    func everyLegacyPresetCompilesClosedRectangularData(
        _ presetID: SymmetryPresetID
    ) throws {
        let compiled = try SymmetryDescriptorCompiler.compile(
            presetID: presetID,
            tileSize: PatternSize(width: 128, height: 192)
        )

        #expect(compiled.presetID == presetID)
        #expect(compiled.domain.periodic != nil)
        #expect(compiled.family == .rectangular)
        #expect(compiled.ownership == .rectangularHalfOpen)
        #expect(compiled.rasterMetric == .identity)
        #expect(compiled.exportCapability == .rectangularRepeat)
        #expect(compiled.displayProgram.family == .rectangular)
        #expect(compiled.displayProgram.presetWireID == presetID.rawValue)
        #expect(compiled.cost.maximumImagesPerCell == compiled.images.count)
        #expect(!compiled.images.isEmpty)
        #expect(
            compiled.domain.periodic?.translationBasis
                == PeriodicTranslationBasis(
                    origin: .zero,
                    u: SIMD2(128, 0),
                    v: SIMD2(0, 192)
                )
        )
    }

    @Test
    func legacyPhaseReflectionAndRotationProgramsAreExact() throws {
        let size = PatternSize(width: 128, height: 192)
        let grid = try SymmetryDescriptorCompiler.compile(
            presetID: .grid,
            tileSize: size
        )
        let halfDrop = try SymmetryDescriptorCompiler.compile(
            presetID: .halfDrop,
            tileSize: size
        )
        let brick = try SymmetryDescriptorCompiler.compile(
            presetID: .brick,
            tileSize: size
        )
        let mirrorX = try SymmetryDescriptorCompiler.compile(
            presetID: .mirrorX,
            tileSize: size
        )
        let mirrorY = try SymmetryDescriptorCompiler.compile(
            presetID: .mirrorY,
            tileSize: size
        )
        let mirrorXY = try SymmetryDescriptorCompiler.compile(
            presetID: .mirrorXY,
            tileSize: size
        )
        let rotational = try SymmetryDescriptorCompiler.compile(
            presetID: .rotational,
            tileSize: size
        )

        #expect(grid.domain.periodic?.phase == nil)
        #expect(
            halfDrop.domain.periodic?.phase
                == PeriodicPhaseProgram(
                    indexAxis: .x,
                    offsetAxis: .y,
                    fractions: [0, 0.5]
                )
        )
        #expect(
            brick.domain.periodic?.phase
                == PeriodicPhaseProgram(
                    indexAxis: .y,
                    offsetAxis: .x,
                    fractions: [0, 0.5]
                )
        )
        #expect(
            mirrorX.domain.periodic?.alternatingReflections == [.x]
        )
        #expect(
            mirrorY.domain.periodic?.alternatingReflections == [.y]
        )
        #expect(
            mirrorXY.domain.periodic?.alternatingReflections == [.x, .y]
        )
        #expect(rotational.images.map(\.ordinal) == [0, 1])
        #expect(
            rotational.images[1].localToCanonical
                == Affine2D(
                    xAxis: SIMD2(-1, 0),
                    yAxis: SIMD2(0, -1),
                    translation: size.simd
                )
        )
        #expect(
            rotational.domain.periodic?.coincidentImagePolicy
                == .halfTurnInvariantCoverage
        )
    }

    @Test
    func validationReturnsTypedDimensionFailures() {
        let cases: [(PatternSize, SymmetryDescriptorError)] = [
            (
                PatternSize(width: .infinity, height: 64),
                .nonFiniteDimension(.width)
            ),
            (
                PatternSize(width: 64, height: .infinity),
                .nonFiniteDimension(.height)
            ),
            (
                PatternSize(width: 64.5, height: 64),
                .nonIntegerDimension(.width)
            ),
            (
                PatternSize(width: 64, height: 64.5),
                .nonIntegerDimension(.height)
            ),
            (
                PatternSize(width: 63, height: 64),
                .dimensionOutOfRange(.width, value: 63)
            ),
            (
                PatternSize(width: 64, height: 4_097),
                .dimensionOutOfRange(.height, value: 4_097)
            ),
        ]

        for (size, expected) in cases {
            #expect(throws: expected) {
                try SymmetryDescriptorCompiler.compile(
                    presetID: .grid,
                    tileSize: size
                )
            }
        }
    }
}
```

- [ ] Run the focused test and confirm it fails because the new types do not
  exist:

```bash
swift test --filter SymmetryDescriptorCompilerTests
```

Expected result: compilation fails on `SymmetryPresetID`,
`CompiledSymmetry`, or `SymmetryDescriptorCompiler`.

### 1.2 Introduce stable selector names without changing persisted bytes

- [ ] Replace the declaration in `Sources/PatternEngine/TilingKind.swift`
  with `SymmetryDocumentDomainID`, `SymmetryPresetID`, and the
  `TilingKind` compatibility typealias shown in **Public Type Contract**.

Do not change any case name or raw value. The alias deliberately lets all
existing call sites, fixtures, JSON decoding, and source tests continue to
compile during migration.

### 1.3 Add the closed descriptor value types

- [ ] Create `Sources/PatternEngine/CompiledSymmetry.swift` with these concrete
  Phase 1 types:

```swift
import Foundation
import simd

public enum SymmetryKernelFamily: UInt32, Codable, Sendable {
    case rectangular = 0
    case triangular = 1
    case radial = 2
}

public enum SymmetryAxis: Equatable, Sendable {
    case x
    case y
}

public struct SymmetryReflectionAxes:
    OptionSet,
    Equatable,
    Sendable
{
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let x = Self(rawValue: 1 << 0)
    public static let y = Self(rawValue: 1 << 1)
}

public struct PeriodicPhaseProgram: Equatable, Sendable {
    public let indexAxis: SymmetryAxis
    public let offsetAxis: SymmetryAxis
    public let fractions: [Float]

    public init(
        indexAxis: SymmetryAxis,
        offsetAxis: SymmetryAxis,
        fractions: [Float]
    ) {
        self.indexAxis = indexAxis
        self.offsetAxis = offsetAxis
        self.fractions = fractions
    }
}

public enum CoincidentImagePolicy: Equatable, Sendable {
    case byteEqualOnly
    case halfTurnInvariantCoverage
}

public struct PeriodicTranslationBasis: Equatable, Sendable {
    public let origin: SIMD2<Float>
    public let u: SIMD2<Float>
    public let v: SIMD2<Float>

    public init(
        origin: SIMD2<Float>,
        u: SIMD2<Float>,
        v: SIMD2<Float>
    ) {
        self.origin = origin
        self.u = u
        self.v = v
    }
}

public struct CompiledPeriodicDomain: Equatable, Sendable {
    public let tileSize: PatternSize
    public let translationBasis: PeriodicTranslationBasis
    public let phase: PeriodicPhaseProgram?
    public let alternatingReflections: SymmetryReflectionAxes
    public let coincidentImagePolicy: CoincidentImagePolicy
}

public enum CompiledSymmetryDomain: Equatable, Sendable {
    case periodic(CompiledPeriodicDomain)

    public var periodic: CompiledPeriodicDomain? {
        guard case let .periodic(value) = self else {
            return nil
        }
        return value
    }
}

public struct CompiledIsometry: Equatable, Sendable {
    public let ordinal: UInt8
    public let localToCanonical: Affine2D
}

public enum CompiledOwnership: Equatable, Sendable {
    case rectangularHalfOpen
}

public struct CompiledDisplayProgram: Equatable, Sendable {
    public let family: SymmetryKernelFamily
    public let presetWireID: UInt32
}

public struct RasterMetric2D: Equatable, Sendable {
    public let worldToRaster: Affine2D
    public let rasterToWorld: Affine2D

    public static let identity = RasterMetric2D(
        worldToRaster: .identity,
        rasterToWorld: .identity
    )
}

public enum SymmetryExportCapability: Equatable, Sendable {
    case rectangularRepeat
}

public struct SymmetryCostBound: Equatable, Sendable {
    public let maximumImagesPerCell: Int
}

public struct CompiledSymmetry: Equatable, Sendable {
    public let presetID: SymmetryPresetID
    public let domain: CompiledSymmetryDomain
    public let family: SymmetryKernelFamily
    public let images: [CompiledIsometry]
    public let ownership: CompiledOwnership
    public let displayProgram: CompiledDisplayProgram
    public let rasterMetric: RasterMetric2D
    public let exportCapability: SymmetryExportCapability
    public let cost: SymmetryCostBound
}
```

The phase compiler uses two images only for `.rotational`; all other legacy
presets use one identity image. Reflection parity is stored separately because
it depends on the signed cell index.

### 1.4 Compile validated descriptors

- [ ] Create `Sources/PatternEngine/SymmetryDescriptorCompiler.swift`.

Define the typed error surface:

```swift
public enum SymmetryDimension: Equatable, Sendable {
    case width
    case height
}

public enum SymmetryDescriptorError: Error, Equatable, Sendable {
    case nonFiniteDimension(SymmetryDimension)
    case nonIntegerDimension(SymmetryDimension)
    case dimensionOutOfRange(SymmetryDimension, value: Float)
}
```

Implement:

```swift
public enum SymmetryDescriptorCompiler {
    public static func compile(
        presetID: SymmetryPresetID,
        tileSize: PatternSize
    ) throws -> CompiledSymmetry {
        try validate(tileSize.width, dimension: .width)
        try validate(tileSize.height, dimension: .height)

        let identity = CompiledIsometry(
            ordinal: 0,
            localToCanonical: .identity
        )
        let phase: PeriodicPhaseProgram?
        let reflections: SymmetryReflectionAxes
        let images: [CompiledIsometry]
        let coincidentPolicy: CoincidentImagePolicy

        switch presetID {
        case .grid:
            phase = nil
            reflections = []
            images = [identity]
            coincidentPolicy = .byteEqualOnly
        case .halfDrop:
            phase = PeriodicPhaseProgram(
                indexAxis: .x,
                offsetAxis: .y,
                fractions: [0, 0.5]
            )
            reflections = []
            images = [identity]
            coincidentPolicy = .byteEqualOnly
        case .brick:
            phase = PeriodicPhaseProgram(
                indexAxis: .y,
                offsetAxis: .x,
                fractions: [0, 0.5]
            )
            reflections = []
            images = [identity]
            coincidentPolicy = .byteEqualOnly
        case .mirrorX:
            phase = nil
            reflections = [.x]
            images = [identity]
            coincidentPolicy = .byteEqualOnly
        case .mirrorY:
            phase = nil
            reflections = [.y]
            images = [identity]
            coincidentPolicy = .byteEqualOnly
        case .mirrorXY:
            phase = nil
            reflections = [.x, .y]
            images = [identity]
            coincidentPolicy = .byteEqualOnly
        case .rotational:
            phase = nil
            reflections = []
            images = [
                identity,
                CompiledIsometry(
                    ordinal: 1,
                    localToCanonical: Affine2D(
                        xAxis: SIMD2(-1, 0),
                        yAxis: SIMD2(0, -1),
                        translation: tileSize.simd
                    )
                ),
            ]
            coincidentPolicy = .halfTurnInvariantCoverage
        }

        return CompiledSymmetry(
            presetID: presetID,
            domain: .periodic(
                CompiledPeriodicDomain(
                    tileSize: tileSize,
                    translationBasis: PeriodicTranslationBasis(
                        origin: .zero,
                        u: SIMD2(tileSize.width, 0),
                        v: SIMD2(0, tileSize.height)
                    ),
                    phase: phase,
                    alternatingReflections: reflections,
                    coincidentImagePolicy: coincidentPolicy
                )
            ),
            family: .rectangular,
            images: images,
            ownership: .rectangularHalfOpen,
            displayProgram: CompiledDisplayProgram(
                family: .rectangular,
                presetWireID: presetID.rawValue
            ),
            rasterMetric: .identity,
            exportCapability: .rectangularRepeat,
            cost: SymmetryCostBound(
                maximumImagesPerCell: images.count
            )
        )
    }
}
```

`validate(_:dimension:)` must check in this order and throw the exact matching
error:

1. `value.isFinite`;
2. `value.rounded(.towardZero) == value`;
3. `(64...4096).contains(value)`.

- [ ] Run:

```bash
swift test --filter SymmetryDescriptorCompilerTests
swift test --filter TilingStrategyTests
```

Expected result: both suites pass. Existing code still uses the compatibility
alias and has no behavioral change.

### 1.5 Review and commit Task 1

- [ ] Verify no raw value moved and no production caller changed:

```bash
git diff --check
git diff -- \
  Sources/PatternEngine/TilingKind.swift \
  Sources/PatternEngine/CompiledSymmetry.swift \
  Sources/PatternEngine/SymmetryDescriptorCompiler.swift \
  Tests/PatternEngineTests/SymmetryDescriptorCompilerTests.swift
rg -n "case (grid|halfDrop|brick|mirrorX|mirrorY|mirrorXY|rotational) =" \
  Sources/PatternEngine/TilingKind.swift
```

- [ ] Stage only Task 1 files and commit:

```bash
git add \
  Sources/PatternEngine/TilingKind.swift \
  Sources/PatternEngine/CompiledSymmetry.swift \
  Sources/PatternEngine/SymmetryDescriptorCompiler.swift \
  Tests/PatternEngineTests/SymmetryDescriptorCompilerTests.swift
git commit -m "feat(symmetry): compile legacy descriptors"
```

---

## Task 2: Move Legacy Geometry Behind the Rectangular Kernel

**Files:**

- Create: `Sources/PatternEngine/RectangularSymmetryKernel.swift`
- Modify: `Sources/PatternEngine/TilingStrategy.swift`
- Create:
  `Tests/PatternEngineTests/RectangularSymmetryKernelParityTests.swift`
- Existing regression:
  `Tests/PatternEngineTests/TilingStrategyTests.swift`

### 2.1 Add parity tests before changing the facade

- [ ] Add
  `Tests/PatternEngineTests/RectangularSymmetryKernelParityTests.swift`.

Use a table covering all seven presets, positive/negative cells, exact
boundaries, rectangular dimensions, and large exactly representable
coordinates. For each tuple, pin the current expected cell and folded point:

```swift
private struct FoldFixture: Sendable {
    let presetID: SymmetryPresetID
    let point: WorldPoint
    let cell: CellIndex
    let canonical: CanonicalPoint
}

private let foldFixtures: [FoldFixture] = [
    .init(
        presetID: .grid,
        point: WorldPoint(x: -1, y: -1),
        cell: CellIndex(column: -1, row: -1),
        canonical: CanonicalPoint(x: 63, y: 95)
    ),
    .init(
        presetID: .halfDrop,
        point: WorldPoint(x: 65, y: 49),
        cell: CellIndex(column: 1, row: 0),
        canonical: CanonicalPoint(x: 1, y: 1)
    ),
    .init(
        presetID: .halfDrop,
        point: WorldPoint(x: -63, y: -47),
        cell: CellIndex(column: -1, row: -1),
        canonical: CanonicalPoint(x: 1, y: 1)
    ),
    .init(
        presetID: .brick,
        point: WorldPoint(x: 33, y: 97),
        cell: CellIndex(column: 0, row: 1),
        canonical: CanonicalPoint(x: 1, y: 1)
    ),
    .init(
        presetID: .brick,
        point: WorldPoint(x: -31, y: -95),
        cell: CellIndex(column: -1, row: -1),
        canonical: CanonicalPoint(x: 1, y: 1)
    ),
    .init(
        presetID: .mirrorX,
        point: WorldPoint(x: 65, y: 1),
        cell: CellIndex(column: 1, row: 0),
        canonical: CanonicalPoint(x: 63, y: 1)
    ),
    .init(
        presetID: .mirrorY,
        point: WorldPoint(x: 1, y: 97),
        cell: CellIndex(column: 0, row: 1),
        canonical: CanonicalPoint(x: 1, y: 95)
    ),
    .init(
        presetID: .mirrorXY,
        point: WorldPoint(x: -1, y: -1),
        cell: CellIndex(column: -1, row: -1),
        canonical: CanonicalPoint(x: 1, y: 1)
    ),
    .init(
        presetID: .rotational,
        point: WorldPoint(x: 65, y: 97),
        cell: CellIndex(column: 1, row: 1),
        canonical: CanonicalPoint(x: 1, y: 1)
    ),
]
```

Test each fixture through the existing `TilingStrategy` before the refactor.
Also pin image order and transforms for:

- grid cell `(0, 0)`: ordinal `[0]`, identity;
- mirror XY cell `(-1, -1)`: ordinal `[0]`, both axes reflected;
- rotational cell `(1, -1)`: ordinals `[0, 1]`, identity first and half-turn
  second;
- an exact right/bottom edge: only the successor half-open cell owns it;
- the same query repeated twice: arrays are exactly equal and ordered by row,
  column, then ordinal.

- [ ] Run:

```bash
swift test --filter RectangularSymmetryKernelParityTests
```

Expected result: the new parity tests pass against the legacy implementation.
This is the before-refactor characterization checkpoint.

### 2.2 Create the descriptor-driven kernel

- [ ] Create `Sources/PatternEngine/RectangularSymmetryKernel.swift` with this
  internal surface:

```swift
import Foundation
import simd

struct RectangularSymmetryKernel: Equatable, Sendable {
    let compiled: CompiledSymmetry
    let periodic: CompiledPeriodicDomain

    init(compiled: CompiledSymmetry) {
        precondition(compiled.family == .rectangular)
        guard case let .periodic(periodic) = compiled.domain else {
            preconditionFailure(
                "RectangularSymmetryKernel requires a periodic descriptor"
            )
        }
        self.compiled = compiled
        self.periodic = periodic
    }

    func cell(containing point: WorldPoint) -> CellIndex
    func images(intersecting worldBounds: AxisAlignedRect) -> [TilingImage]
    func displayFold(_ point: WorldPoint) -> CanonicalPoint
}
```

Move the current numeric helpers from `TilingStrategy.swift` into this file
without changing their arithmetic, check order, or precondition text:

- `positiveModulo`;
- `parity`;
- `CoordinateAxis`;
- `checkedCellIndex`;
- `resolvedCellIndex`;
- `quotientCellIndex`;
- `exactCellIndex`;
- `intersectingIndices`.

Drive the former `.halfDrop` and `.brick` branches from
`periodic.phase`. The phase fraction is selected with positive signed modulo:

```swift
private func phaseFraction(
    for index: Int,
    program: PeriodicPhaseProgram
) -> Float {
    let count = program.fractions.count
    let remainder = index % count
    let resolved = remainder >= 0 ? remainder : remainder + count
    return program.fractions[resolved]
}
```

The current two-phase descriptors therefore preserve negative odd parity:
`-1` selects fraction `0.5`, `-2` selects fraction `0`.

Build unphased cell origins from the compiled translation basis:

```swift
let unphasedOrigin =
    periodic.translationBasis.origin
    + periodic.translationBasis.u * Float(cell.column)
    + periodic.translationBasis.v * Float(cell.row)
```

Then add the selected phase fraction times the tile extent on the program's
offset axis. This keeps current rectangular arithmetic while establishing the
common periodic-lattice descriptor required by the governing spec.

Drive reflection from `periodic.alternatingReflections`. For a given cell:

```swift
let reflectsX = periodic.alternatingReflections.contains(.x)
    && !cell.column.isMultiple(of: 2)
let reflectsY = periodic.alternatingReflections.contains(.y)
    && !cell.row.isMultiple(of: 2)
```

Generate each image by composing world-to-local, the parity reflection, then
the compiled local image:

```swift
let worldToLocal = Affine2D(
    xAxis: SIMD2(1, 0),
    yAxis: SIMD2(0, 1),
    translation: -origin
)
let parityToCanonical = Affine2D(
    xAxis: SIMD2(reflectsX ? -1 : 1, 0),
    yAxis: SIMD2(0, reflectsY ? -1 : 1),
    translation: SIMD2(
        reflectsX ? periodic.tileSize.width : 0,
        reflectsY ? periodic.tileSize.height : 0
    )
)
let worldToCanonical = worldToLocal
    .concatenating(parityToCanonical)
    .concatenating(compiledImage.localToCanonical)
```

For the seven Phase 1 descriptors, reflection and multi-image rotation never
coexist, so the composition produces the exact existing transforms. Keep the
current image filtering, `result.contains`, row/column sort, and ordinal order
unchanged.

`displayFold` must:

1. resolve the descriptor-driven cell;
2. subtract the compiled phase on its offset axis;
3. fold both coordinates with the unchanged `positiveModulo`;
4. apply the signed-cell parity reflection;
5. return the same canonical result as the legacy switch.

### 2.3 Turn `TilingStrategy` into the compatibility facade

- [ ] Modify `Sources/PatternEngine/TilingStrategy.swift`.

Retain `CellIndex` and `TilingImage` as public compatibility types. Change
`TilingStrategy` to store one compiled value and delegate:

```swift
public struct TilingStrategy: Equatable, Sendable {
    public let presetID: SymmetryPresetID
    public let tileSize: PatternSize
    public let compiledSymmetry: CompiledSymmetry

    public var kind: TilingKind { presetID }

    public init(kind: TilingKind, tileSize: PatternSize) {
        // Keep all six existing dimension preconditions here, in their
        // existing order and with their exact strings.
        presetID = kind
        self.tileSize = tileSize
        do {
            compiledSymmetry = try SymmetryDescriptorCompiler.compile(
                presetID: kind,
                tileSize: tileSize
            )
        } catch {
            preconditionFailure(
                "TilingStrategy validated dimensions must compile"
            )
        }
    }

    public func cell(containing point: WorldPoint) -> CellIndex {
        RectangularSymmetryKernel(
            compiled: compiledSymmetry
        ).cell(containing: point)
    }

    public func images(
        intersecting worldBounds: AxisAlignedRect
    ) -> [TilingImage] {
        // Keep the four exact finite-bound preconditions and empty-bound
        // return before delegating.
        return RectangularSymmetryKernel(
            compiled: compiledSymmetry
        ).images(intersecting: worldBounds)
    }

    public func displayFold(_ point: WorldPoint) -> CanonicalPoint {
        RectangularSymmetryKernel(
            compiled: compiledSymmetry
        ).displayFold(point)
    }
}
```

There must be no `switch presetID` or `switch kind` left in
`TilingStrategy.swift` or `RectangularSymmetryKernel.swift`. The only Phase 1
preset switch belongs to the cold-path compiler and the independent oracle.

### 2.4 Prove the facade is behaviorally unchanged

- [ ] Run:

```bash
swift test --filter SymmetryDescriptorCompilerTests
swift test --filter RectangularSymmetryKernelParityTests
swift test --filter TilingStrategyTests
swift test --filter TilingProjectionTests
```

Expected result: all pass with unchanged exact boundary/precondition fixtures.

- [ ] Prove the switch boundary:

```bash
if rg -n "switch (kind|presetID)" \
  Sources/PatternEngine/TilingStrategy.swift \
  Sources/PatternEngine/RectangularSymmetryKernel.swift
then
  exit 1
fi
rg -n "switch presetID" \
  Sources/PatternEngine/SymmetryDescriptorCompiler.swift
```

Expected result: the negative search finds nothing; the positive search finds
the compiler switch.

### 2.5 Review and commit Task 2

- [ ] Run `git diff --check`, inspect only Task 2 files, and commit:

```bash
git add \
  Sources/PatternEngine/RectangularSymmetryKernel.swift \
  Sources/PatternEngine/TilingStrategy.swift \
  Tests/PatternEngineTests/RectangularSymmetryKernelParityTests.swift
git commit -m "refactor(symmetry): use rectangular kernel"
```

---

## Task 3: Make Projection Deduplication Descriptor-Driven

**Files:**

- Modify: `Sources/PatternEngine/TilingProjection.swift`
- Modify: `Tests/PatternEngineTests/TilingProjectionTests.swift`

### 3.1 Pin the policy rather than the preset name

- [ ] Add tests to `TilingProjectionTests.swift` that compile the seven
  strategies and assert:

- byte-equal candidate removal runs for every preset;
- coverage-equal candidate removal runs only when
  `coincidentImagePolicy == .halfTurnInvariantCoverage` and the footprint is
  `.halfTurnInvariant`;
- asymmetric rotational footprints keep both distinct image ordinals;
- a rotational hard-round fixed point deduplicates to one fragment;
- all other legacy presets retain their prior fragment count and transform
  order.

Name the primary test:

```swift
@Test
func coincidentRemovalFollowsCompiledPolicyNotPresetBranch()
```

- [ ] Before the implementation change, use a source assertion in the test to
  establish the old branch still exists:

```swift
let source = try String(
    contentsOf: packageRoot()
        .appending(path: "Sources/PatternEngine/TilingProjection.swift"),
    encoding: .utf8
)
#expect(source.contains("strategy.kind == .rotational"))
```

Run:

```bash
swift test --filter coincidentRemovalFollowsCompiledPolicyNotPresetBranch
```

Expected result: the behavioral assertions pass and the source assertion proves
the legacy branch is still present.

### 3.2 Replace the name check with compiled policy

- [ ] Modify `TilingProjection.fragments`:

```swift
candidates = removingByteEqualCandidates(candidates)
if
    strategy.compiledSymmetry.domain.periodic?
        .coincidentImagePolicy == .halfTurnInvariantCoverage,
    footprint.coverageSymmetry == .halfTurnInvariant
{
    candidates = removingCoverageEqualCandidates(candidates)
}
```

Change the source assertion to:

```swift
#expect(!source.contains("strategy.kind == .rotational"))
#expect(
    source.contains(
        ".coincidentImagePolicy == .halfTurnInvariantCoverage"
    )
)
```

Do not broaden `FootprintCoverageSymmetry` or infer material equivalence in
this phase. The existing policy is intentionally as narrow as legacy
rotational deduplication.

### 3.3 Verify and commit Task 3

- [ ] Run:

```bash
swift test --filter TilingProjectionTests
swift test --filter TilingCoverageOracleTests
git diff --check
```

Expected result: all tests pass; the oracle source remains unmodified.

- [ ] Commit:

```bash
git add \
  Sources/PatternEngine/TilingProjection.swift \
  Tests/PatternEngineTests/TilingProjectionTests.swift
git commit -m "refactor(symmetry): drive projection policy"
```

---

## Task 4: Add the Family Dispatch Seam to the Metal ABI

**Files:**

- Modify: `Sources/CShaderTypes/include/ShaderTypes.h`
- Modify: `Sources/MetalRenderer/ShaderABI.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/Shaders.metal`
- Modify: `Tests/MetalRendererTests/ShaderABILayoutTests.swift`
- Modify: `Tests/MetalRendererTests/ReflectedRotationalShaderTests.swift`
- Modify: `Tests/MetalRendererTests/TranslationTilingShaderTests.swift`

### 4.1 Write failing ABI and source-contract tests

- [ ] In `ShaderABILayoutTests.swift`, replace the offset assertion for
  `\.padding` with `\.symmetryFamily`, retaining offset `52`, size `56`, stride
  `56`, and alignment `8`.

Add:

```swift
@Test
func symmetryFamilyWireValuesAreAppendOnly() {
    #expect(PatternSymmetryFamilyWireRectangular == 0)
    #expect(PatternSymmetryFamilyWireTriangular == 1)
    #expect(PatternSymmetryFamilyWireRadial == 2)
}
```

- [ ] In `ReflectedRotationalShaderTests.swift`, require renderer source to
  contain:

```text
tilingKind: tilingStrategy.compiledSymmetry.displayProgram.presetWireID
symmetryFamily: tilingStrategy.compiledSymmetry.displayProgram.family.rawValue
```

and require shader source to contain:

```text
uint symmetryFamily
symmetryFamily != PatternSymmetryFamilyWireRectangular
```

Retain every existing legacy selector and case assertion.

- [ ] In `TranslationTilingShaderTests.swift`, require the fragment call to
  pass `frame.symmetryFamily` into `patternDisplayMapping`.

- [ ] Run:

```bash
swift test --filter ShaderABILayoutTests
swift test --filter ReflectedRotationalShaderTests
swift test --filter TranslationTilingShaderTests
```

Expected result: the focused tests fail on the absent field/constants and old
renderer source.

### 4.2 Repurpose only the existing padding word

- [ ] In `ShaderTypes.h`, rename the last
  `PatternGridFrameUniforms` field:

```c
PatternUInt32 symmetryFamily;
```

Add after material/shape/grain constants and before tiling constants:

```c
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternSymmetryFamilyWireRectangular = 0;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternSymmetryFamilyWireTriangular = 1;
PATTERN_WIRE_CONSTANT PatternUInt32
    PatternSymmetryFamilyWireRadial = 2;
```

Do not change the struct size or move any existing field.

- [ ] In `ShaderABI.swift`, assert `\.symmetryFamily == 52` and leave every
  other layout assertion untouched.

### 4.3 Feed the compiled display program to the frame

- [ ] In `GridRenderer.frameUniforms`, replace:

```swift
return PatternGridFrameUniforms(
    drawableSize: drawableSize.simd,
    worldCenter: viewport.worldCenter.simd,
    tileSize: tileSize.simd,
    zoom: viewport.zoom,
    gridLineWidth: 1,
    showGridLines: showGridLines ? 1 : 0,
    liveVisible: liveVisible ? 1 : 0,
    tilingKind: tilingStrategy.kind.rawValue,
    diagnosticMode: diagnosticMode,
    compositeMode: compositeMode,
    padding: 0
)
```

with:

```swift
return PatternGridFrameUniforms(
    drawableSize: drawableSize.simd,
    worldCenter: viewport.worldCenter.simd,
    tileSize: tileSize.simd,
    zoom: viewport.zoom,
    gridLineWidth: 1,
    showGridLines: showGridLines ? 1 : 0,
    liveVisible: liveVisible ? 1 : 0,
    tilingKind:
        tilingStrategy.compiledSymmetry.displayProgram.presetWireID,
    diagnosticMode: diagnosticMode,
    compositeMode: compositeMode,
    symmetryFamily:
        tilingStrategy.compiledSymmetry.displayProgram.family.rawValue
)
```

No renderer hot path may invoke the descriptor compiler.

### 4.4 Dispatch by family before the unchanged rectangular switch

- [ ] Change `patternDisplayMapping` in `Shaders.metal` to:

```metal
static PatternDisplayMapping patternDisplayMapping(
    float2 world,
    float2 tileSize,
    uint symmetryFamily,
    uint tilingKind
) {
    if (symmetryFamily != PatternSymmetryFamilyWireRectangular) {
        return {float2(0.0), float2(0.0), false};
    }

    switch (tilingKind) {
    case PatternTilingWireHalfDrop: {
        const int column = int(floor(world.x / tileSize.x));
        const float phaseY = (column & 1) * tileSize.y * 0.5;
        const float2 folded = patternPositiveFold(
            float2(world.x, world.y - phaseY),
            tileSize
        );
        return {folded, folded, true};
    }
    case PatternTilingWireBrick: {
        const int row = int(floor(world.y / tileSize.y));
        const float phaseX = (row & 1) * tileSize.x * 0.5;
        const float2 folded = patternPositiveFold(
            float2(world.x - phaseX, world.y),
            tileSize
        );
        return {folded, folded, true};
    }
    case PatternTilingWireMirrorX:
    case PatternTilingWireMirrorY:
    case PatternTilingWireMirrorXY: {
        const int column = int(floor(world.x / tileSize.x));
        const int row = int(floor(world.y / tileSize.y));
        const float2 local = patternPositiveFold(world, tileSize);
        const bool reflectsX =
            (
                tilingKind == PatternTilingWireMirrorX
                || tilingKind == PatternTilingWireMirrorXY
            )
            && (column & 1) != 0;
        const bool reflectsY =
            (
                tilingKind == PatternTilingWireMirrorY
                || tilingKind == PatternTilingWireMirrorXY
            )
            && (row & 1) != 0;
        const float2 canonical = float2(
            reflectsX
                ? patternPositiveFold(tileSize.x - local.x, tileSize.x)
                : local.x,
            reflectsY
                ? patternPositiveFold(tileSize.y - local.y, tileSize.y)
                : local.y
        );
        return {canonical, local, true};
    }
    case PatternTilingWireRotational: {
        const float2 folded = patternPositiveFold(world, tileSize);
        return {folded, folded, true};
    }
    case PatternTilingWireGrid: {
        const float2 folded = patternPositiveFold(world, tileSize);
        return {folded, folded, true};
    }
    default:
        return {float2(0.0), float2(0.0), false};
    }
}
```

Pass `frame.symmetryFamily` before `frame.tilingKind` at the fragment call.
The magenta invalid mapping remains the explicit unsupported-family signal.
Do not add triangular or radial shader cases.

### 4.5 Verify ABI and shader compilation

- [ ] Run:

```bash
swift test --filter ShaderABILayoutTests
swift test --filter ReflectedRotationalShaderTests
swift test --filter TranslationTilingShaderTests
swift test --filter RendererRasterOperationTests
./scripts/bootstrap.sh
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  build CODE_SIGNING_ALLOWED=NO
```

Expected result: all tests pass, Metal compiles, and the macOS app builds.

### 4.6 Review and commit Task 4

- [ ] Confirm the binary layout and legacy wires did not move:

```bash
git diff --check
rg -n "PatternTilingWire(Grid|HalfDrop|Brick|MirrorX|MirrorY|MirrorXY|Rotational)" \
  Sources/CShaderTypes/include/ShaderTypes.h
```

- [ ] Commit:

```bash
git add \
  Sources/CShaderTypes/include/ShaderTypes.h \
  Sources/MetalRenderer/ShaderABI.swift \
  Sources/MetalRenderer/GridRenderer.swift \
  Sources/MetalRenderer/Shaders.metal \
  Tests/MetalRendererTests/ShaderABILayoutTests.swift \
  Tests/MetalRendererTests/ReflectedRotationalShaderTests.swift \
  Tests/MetalRendererTests/TranslationTilingShaderTests.swift
git commit -m "feat(metal): dispatch compiled symmetry family"
```

---

## Task 5: Prove Independent Oracle and Byte-for-Byte Legacy Parity

**Files:**

- Modify:
  `Tests/PatternEngineTests/TilingCoverageOracleTests.swift`
- Modify: `Tests/MetalRendererTests/HarnessSceneTests.swift`
- Do not modify:
  `Sources/PatternEngine/Verification/TilingCoverageOracle.swift`
- Existing real-Metal scenes:
  `App/PatternSpike/Harness/Scenes/*.json`

### 5.1 Add a production-versus-oracle parity matrix

- [ ] Extend `TilingCoverageOracleTests.swift` with
  `compiledDescriptorsMatchIndependentOracleAcrossLegacyMatrix()`.

Build a deterministic matrix over:

- all seven `SymmetryPresetID` cases;
- square `64 x 64` and rectangular `64 x 96` repeat units;
- identity, translated, rotated, reflected, and sheared brush transforms;
- hard-round and asymmetric-triangle oracle footprints;
- centres in the base cell, positive odd cells, negative odd cells, exact
  right/bottom boundaries, seams, corners, and large representable cells;
- supersampling `1`, `2`, and `4`.

For each case:

1. compile `TilingStrategy`;
2. project the matching `StampFootprint`;
3. rasterize projected fragments with the file's existing private
   `rasterizeProductionFragments` helper;
4. independently call `TilingCoverageOracle.renderCanonical`;
5. compare coverage bytes exactly;
6. compare canonical-coordinate and brush-local diagnostic bytes exactly when
   the existing rasterizer exposes them;
7. include the preset, size, transform, footprint, and supersampling in the
   failure message.

The test must not pass `compiledSymmetry`, `CompiledIsometry`,
`CompiledOwnership`, or `CompiledDisplayProgram` into the oracle.

### 5.2 Add an oracle-independence source guard

- [ ] Add this test to `TilingCoverageOracleTests.swift`:

```swift
@Test
func oracleDoesNotConsumeProductionDescriptors() throws {
    let source = try String(
        contentsOf: packageRoot()
            .appending(
                path:
                    "Sources/PatternEngine/Verification/TilingCoverageOracle.swift"
            ),
        encoding: .utf8
    )

    #expect(source.contains("tiling: TilingKind"))
    #expect(!source.contains("CompiledSymmetry"))
    #expect(!source.contains("CompiledIsometry"))
    #expect(!source.contains("CompiledOwnership"))
    #expect(!source.contains("CompiledDisplayProgram"))
}
```

The compatibility alias means this remains the same stable selector type while
making the independence boundary explicit.

### 5.3 Pin harness schema compatibility

- [ ] Extend `HarnessSceneTests.swift` with one decoding test that feeds raw
  JSON values `0...6` and expects the corresponding `SymmetryPresetID`. Reuse
  the existing schema helper and do not add a new JSON field.

- [ ] Add a round-trip test proving encoding still writes the numeric `tiling`
  field and does not emit `presetID`, `symmetryFamily`, or descriptor data.

### 5.4 Run all CPU parity tests

- [ ] Run:

```bash
swift test \
  --filter compiledDescriptorsMatchIndependentOracleAcrossLegacyMatrix
swift test --filter TilingCoverageOracleTests
swift test --filter HarnessSceneTests
swift test --filter TilingStrategyTests
swift test --filter TilingProjectionTests
```

Expected result: every comparison is byte-equal and the oracle-independence
guard passes.

### 5.5 Run existing real-Metal legacy scenes

- [ ] Build the macOS app:

```bash
./scripts/bootstrap.sh
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  build CODE_SIGNING_ALLOWED=NO
```

- [ ] Run the existing positive/negative scene pairs for:

- generalized grid;
- half-drop interior, edge, and corner;
- brick transpose;
- mirror X, mirror Y, and mirror XY;
- rotational generator, fixed point, and orientation;
- asymmetric footprint;
- canonical and brush-local coordinate continuity;
- noncentral visible cells for every legacy preset;
- metadata tiling switch.

Use the existing slice harness runner and validators rather than inventing a
second renderer. Every negative control must fail with its expected typed
metric, and every positive scene must pass against the existing independent
oracle and artifact contract.

If the checkout remains dirty because of preserved user files, run the harness
scene commands directly and record that the clean-source wrapper was not used.
Do not weaken an existing provenance check.

The direct dirty-checkout command is:

```bash
set -euo pipefail
binary=".build/DerivedData/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike"
scenes="App/PatternSpike/Harness/Scenes"
artifacts=".build/symmetry-phase1-artifacts"
git_commit="$(git rev-parse HEAD)"
if [[ -e "$artifacts" ]]; then
  printf 'artifact directory already exists: %s\n' "$artifacts" >&2
  exit 1
fi
mkdir -p "$artifacts/negative-control" "$artifacts/positive"

for name in \
  generalized-grid \
  halfdrop-interior \
  halfdrop-edge \
  halfdrop-corner \
  brick-transpose \
  mirror-x \
  mirror-y \
  mirror-xy \
  rotational-generator \
  rotational-fixed-point \
  rotational-orientation \
  asymmetric-footprint \
  canonical-coordinate-continuity \
  brush-local-coordinate-continuity \
  noncentral-visible-cell-grid \
  noncentral-visible-cell-halfdrop \
  noncentral-visible-cell-brick \
  noncentral-visible-cell-mirror-x \
  noncentral-visible-cell-mirror-y \
  noncentral-visible-cell-mirror-xy \
  noncentral-visible-cell-rotational \
  metadata-tiling-switch
do
  negative="$name-negative-control"
  negative_output="$artifacts/negative-control/$negative"
  positive_output="$artifacts/positive/$name"
  mkdir -p "$negative_output" "$positive_output"

  if "$binary" \
    --harness-scene "$scenes/$negative.json" \
    --output-directory "$negative_output" \
    --git-commit "$git_commit" \
    --configuration Debug \
    >"$negative_output/stdout.log" \
    2>"$negative_output/stderr.log"
  then
    printf 'negative control unexpectedly passed: %s\n' "$negative" >&2
    exit 1
  fi
  grep -q "^HARNESS FAIL .*scene '$negative'.*" \
    "$negative_output/stderr.log"

  "$binary" \
    --harness-scene "$scenes/$name.json" \
    --output-directory "$positive_output" \
    --git-commit "$git_commit" \
    --configuration Debug \
    >"$positive_output/stdout.log" \
    2>"$positive_output/stderr.log"
  grep -q "^HARNESS PASS scene=$name " "$positive_output/stdout.log"
  test -s "$positive_output/$name.benchmark.json"
done
```

Expected result: each negative process exits nonzero with a typed `HARNESS
FAIL` line; each positive process exits zero, prints `HARNESS PASS`, and emits
its benchmark record beneath `.build/symmetry-phase1-artifacts/positive/`.

- [ ] Compare every post-refactor PNG byte-for-byte with the baseline captured
  before Task 1:

```bash
(
  cd .build/symmetry-phase1-artifacts/positive
  find . -type f -name '*.png' -print0 \
    | sort -z \
    | xargs -0 shasum -a 256
) >.build/symmetry-phase1-current.sha256
diff -u \
  .build/symmetry-phase1-legacy-baseline.sha256 \
  .build/symmetry-phase1-current.sha256
```

Expected result: `diff` produces no output. Any changed byte blocks the phase,
even when the image looks visually equivalent.

### 5.6 Review and commit Task 5

- [ ] Verify:

```bash
git diff --check
git diff -- \
  Tests/PatternEngineTests/TilingCoverageOracleTests.swift \
  Tests/MetalRendererTests/HarnessSceneTests.swift
git diff --exit-code -- \
  Sources/PatternEngine/Verification/TilingCoverageOracle.swift
```

Expected result: no oracle production-source diff.

- [ ] Commit:

```bash
git add \
  Tests/PatternEngineTests/TilingCoverageOracleTests.swift \
  Tests/MetalRendererTests/HarnessSceneTests.swift
git commit -m "test(symmetry): prove legacy parity"
```

---

## Task 6: Complete Cross-Target Verification and Phase Evidence

**Files:**

- Create:
  `docs/superpowers/milestones/05-compiled-symmetry-foundation.md`
- Modify: `docs/superpowers/milestones/README.md`

### 6.1 Run the complete regression gate

- [ ] Run:

```bash
swift test --no-parallel
./scripts/bootstrap.sh
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  build CODE_SIGNING_ALLOWED=NO
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedDataPad \
  build CODE_SIGNING_ALLOWED=NO
```

Expected result: Swift tests pass with zero failures and both targets report
`BUILD SUCCEEDED`.

- [ ] Run source-boundary checks:

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

Expected result: both negative searches are empty and the diff check passes.

### 6.2 Write the Phase 1 milestone

- [ ] Create
  `docs/superpowers/milestones/05-compiled-symmetry-foundation.md` with:

- governing spec and this implementation plan;
- commit hashes for Tasks 1 through 5;
- exact raw-value table for document domain, kernel family, and presets;
- descriptor compilation and validation summary;
- proof that `TilingStrategy` is now a compatibility facade;
- proof that projection policy comes from the compiled descriptor;
- ABI table showing `PatternGridFrameUniforms` still has size/stride `56` and
  the family selector occupies former padding at offset `52`;
- focused and full Swift test commands/results;
- macOS and iPad build commands/results;
- real-Metal scene matrix and artifact locations;
- explicit oracle-independence evidence;
- remaining limitations, naming Phases 2 through 5 rather than describing them
  as defects;
- any provenance gate that could not run because unrelated user files remained
  dirty, with the direct scene evidence used instead.

- [ ] Add the new milestone to
  `docs/superpowers/milestones/README.md` after Slice 4. Label it
  “Compiled symmetry Phase 1,” not “Slice 5,” because product Slice 5 already
  has separate meaning in the stroke roadmap.

### 6.3 Review the complete diff against the governing spec

- [ ] Review every changed production file and answer these checks in the
  milestone:

1. Are raw values `0...6` unchanged?
2. Does Codable still emit the same numeric values?
3. Are all seven modes compiled from named descriptors?
4. Is the descriptor complete before the hot path receives it?
5. Are geometry and dedup driven by compiled data?
6. Does Metal dispatch on family plus unchanged preset wire?
7. Is the independent oracle descriptor-free?
8. Are canonical raster bytes and metadata-switch semantics unchanged?
9. Do macOS and iPad targets build?
10. Did this phase avoid square, triangular, radial, per-layer, and export
    scope?

Any “no” blocks completion.

### 6.4 Commit milestone evidence

- [ ] Stage only milestone files:

```bash
git add \
  docs/superpowers/milestones/05-compiled-symmetry-foundation.md \
  docs/superpowers/milestones/README.md
git commit -m "docs(symmetry): record foundation evidence"
```

Do not push until the user asks.

---

## Final Definition of Done

Phase 1 is complete only when all of the following are true:

- `SymmetryPresetID` is the stable selector and legacy `TilingKind` source
  continues through a compatibility alias;
- preset IDs and JSON bytes `0...6` are unchanged;
- all seven legacy presets compile into closed `CompiledSymmetry` values;
- invalid dimensions return typed compiler errors;
- `TilingStrategy` delegates to `RectangularSymmetryKernel`;
- no legacy preset switch remains in the production geometry facade/kernel;
- projection deduplication reads descriptor policy;
- Metal receives `symmetryFamily` without changing ABI size or existing offsets;
- the rectangular shader path preserves all seven legacy cases;
- CPU production results are byte-equal to independent oracle results;
- existing real-Metal positive scenes pass and negative controls fail as
  designed;
- the oracle imports no production descriptor type;
- the full Swift suite and both application builds pass;
- milestone evidence records commands, outputs, commits, and any remaining
  Phase 2 through Phase 5 work;
- unrelated user changes remain untouched.
