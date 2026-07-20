# Generalized Seam-Correct Tiling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Use
> `superpowers:test-driven-development` for each behavior change,
> `superpowers:requesting-code-review` at every review gate, and
> `superpowers:verification-before-completion` before every commit. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Slice 1's grid-only center-fold shortcut with one bounded,
full-affine cell-fragment projector used by all seven tilings, verify it against
an independent CPU oracle and the real app metallib, support rectangular
canonical tiles and drawing through visible cells, and add an idle-only,
pixel-preserving tiling selector.

**Architecture:** `PatternEngine` owns finite affine geometry, the seven
tiling definitions, fragment projection, and a deliberately independent
coverage oracle. `CShaderTypes` owns the append-only wire contract and exact
96-byte projected-stamp instance. `MetalRenderer` remains the only production
renderer: it stamps projected fragments, folds display samples, preserves the
persistent live/commit lifecycle, and exposes deterministic harness seams.
`EditorCore` owns only confirmed tiling metadata; the app applies renderer
state first and updates the model only after acceptance.

**Tech Stack:** Swift 6, Swift Testing, Foundation, simd, Observation, Metal,
MetalKit, AppKit, SwiftUI, C/MSL shared ABI, CoreGraphics, ImageIO, XcodeGen
2.46.0 or newer, Xcode command-line tools.

**Authority:** The approved
`docs/superpowers/specs/2026-07-20-generalized-seam-correct-tiling-design.md`
and its approved parent
`docs/superpowers/specs/2026-07-18-pattern-product-rebuild-design.md` govern.
Recovered documents are evidence only. Where they conflict, the approved
specifications win.

**Execution mode:** Work directly on `main`, as explicitly requested. Do not
create a branch or worktree. Complete one task, obtain a fresh review, run its
gate, and commit before starting the next task. Preserve unrelated user
changes.

---

## Explicit Start-Gate Override

The user explicitly decided on 2026-07-20 that Slice 1's pending performance
acceptance does not block Slice 2 implementation. Task 0 preserves the full
Slice 1 functional gate while allowing only its performance evaluator to be
skipped. Do not weaken or relabel Slice 1 measurements, skip functional
regressions, or substitute CPU rendering.

---

## Global Constraints

- World, screen, canonical, and brush-local coordinates increase rightward and
  downward.
- Canonical storage is half-open `[0, width) x [0, height)`.
- Tile width and height are independent integers in `64...4096`.
- User-facing diameter is
  `2...min(2000, 8 * min(tileWidth, tileHeight))`; engine radius is half that
  value. The interactive Slice 2 brush remains radius `10`.
- Projection uses `Float`, signed cell indices, finite geometry, normalized
  half-planes, no more than four clip planes, and deterministic ordering.
- The maximum clamped radius is
  `min(requestedRadius, 1000, 4 * min(tileWidth, tileHeight))`; enumeration is
  bounded to at most `9 x 9` translation cells before rotational images.
- Production and oracle code may share primitive geometry and `TilingKind`
  only. The oracle must not call `TilingStrategy`, `TilingProjection`, reuse
  fragments, or replay GPU instances.
- Metal enters at the first integrated vertical slice and remains the only
  production renderer. The oracle is never an interactive fallback.
- The active stroke is discardable. Preview and commit use the same stored
  fragments and source-over math. Only a new monotonic instance suffix is
  encoded per frame.
- Tiling changes are idle-only, update metadata/display projection, and never
  mutate canonical bytes or revisions.
- Wire values `0...6`, buffer indices `0...2`, and texture indices `0...1`
  remain unchanged. New wire values append only.
- Legacy harness schema 1 and 2 scenes continue to decode and pass unchanged.
- Every new harness family receives a deliberate negative control before its
  positive scene is accepted.
- `PatternEngine` imports Foundation and simd only. It must not import Metal,
  MetalKit, Observation, SwiftUI, AppKit, or UIKit.
- `EditorCore` may import Observation and PatternEngine; it must not import
  SwiftUI, Metal, AppKit, or UIKit.
- Generated `.build/` and `App/PatternSpike.xcodeproj/` artifacts remain
  ignored and uncommitted.
- Do not add Slice 3 transactions, undo, color, erasing, layers, selection,
  persistence, export, Pencil behavior, or production brush assets.

---

## File Map

```text
Sources/
  PatternEngine/
    Geometry.swift                                  # existing point/size values
    Affine2D.swift                                  # affine composition/inverse
    ConvexGeometry.swift                            # bounds and validated clips
    TilingKind.swift                                # seven append-only selectors
    TilingStrategy.swift                            # folds, cells, finite images
    StampFootprint.swift                            # oriented source bounds
    TilingProjection.swift                          # production fragments only
    Verification/
      TilingCoverageOracle.swift                    # independent direct-fold truth
  CShaderTypes/include/ShaderTypes.h                # shared 96-byte ABI
  EditorCore/
    Model/EditorModel.swift                         # confirmed tiling metadata only
  MetalRenderer/
    ShaderABI.swift                                 # runtime CPU/MSL layout guard
    ProjectedStampInstance.swift                    # fragment-to-C packing
    GridCanvasContract.swift                        # bounded capacities/defaults
    LiveStroke.swift                                # projected-instance identity
    DabInstanceBufferPool.swift                     # 96-byte instance uploads
    GridPipelineLibrary.swift                       # production + harness pipelines
    GridRenderer.swift                              # generalized renderer state
    MetalRendererError.swift                        # typed runtime failures
    Shaders.metal                                   # stamp/display/commit/diagnostics
    Capture/
      HarnessScene.swift                            # append-only schema 3 vocabulary
      HarnessRunner.swift                           # fixed real-metallib programs
      PNGWriter.swift                               # texture and oracle artifacts
App/
  project.yml                                      # add EditorCore dependency
  PatternSpike/
    ContentView.swift                               # native idle-only selector
    Canvas/MetalCanvas.swift                        # renderer/model state bridge
    Canvas/InteractiveMetalView.swift               # input only, unchanged math
    Harness/Scenes/
      generalized-grid{,-negative-control}.json
      halfdrop-{interior,edge,corner}{,-negative-control}.json
      brick-transpose{,-negative-control}.json
      mirror-{x,y,xy}{,-negative-control}.json
      rotational-{generator,fixed-point,orientation}{,-negative-control}.json
      large-footprint{,-negative-control}.json
      asymmetric-footprint{,-negative-control}.json
      canonical-coordinate-continuity{,-negative-control}.json
      brush-local-coordinate-continuity{,-negative-control}.json
      rectangular-tile{,-negative-control}.json
      noncentral-visible-cell-{grid,halfdrop,brick,mirror-x,mirror-y,mirror-xy,rotational}{,-negative-control}.json
      metadata-tiling-switch{,-negative-control}.json
      projected-live-commit{,-negative-control}.json
      projected-long-stroke{,-negative-control}.json
Tests/
  PatternEngineTests/
    Affine2DTests.swift
    ConvexGeometryTests.swift
    TilingStrategyTests.swift
    TilingProjectionTests.swift
    TilingCoverageOracleTests.swift
  EditorCoreTests/
    EditorModelTests.swift
  MetalRendererTests/
    ShaderABILayoutTests.swift
    ProjectedStampInstanceTests.swift
    GridCanvasContractTests.swift
    LiveStrokeTests.swift
    HarnessSceneTests.swift
scripts/
  verify-slice2.sh
docs/superpowers/milestones/
  02-generalized-seam-correct-tiling.md
```

Responsibility boundaries:

- `Affine2D.swift` contains no tiling cases; it only transforms, composes, and
  inverts finite affine values.
- `ConvexGeometry.swift` validates bounds and no-more-than-four normalized
  half-planes.
- `TilingStrategy.swift` is the production mathematical definition. It owns
  point folds and finite cell images, not brush coverage or GPU packing.
- `TilingProjection.swift` maps one conservative footprint into sorted,
  deduplicated cell fragments. It performs no rasterization.
- `TilingCoverageOracle.swift` owns a direct `switch` over `TilingKind` and
  writes expected pixels without referencing production strategy/projection.
- `ProjectedStampInstance.swift` is the only Swift-to-C packing seam.
- `GridRenderer.swift` retains its public name for source compatibility but
  contains no grid-only projection branch after Task 5.
- `HarnessRunner.swift` is the only caller allowed to select diagnostic
  fragment modes.
- `EditorModel` stores only confirmed `TilingKind`; renderer lifecycle remains
  authoritative for whether a change can occur.

---

### Task 0: Preserve Slice 1 Functional Regression Coverage

**Files:**
- Modify: `scripts/verify-slice1.sh`

- [ ] **Step 1: Prove the override flag does not bypass performance yet**

Run:

```bash
PATTERN_SKIP_PERFORMANCE=1 ./scripts/verify-slice1.sh
```

Expected: FAIL at the existing performance evaluator, proving the new flag is
not implemented yet. All functional stages before that evaluator must pass.

- [ ] **Step 2: Add an explicit performance-only bypass**

Wrap only the inline Swift performance evaluator in:

```bash
if [[ "${PATTERN_SKIP_PERFORMANCE:-0}" == "1" ]]; then
  printf '%s\n' "slice1-performance=skipped-explicit-user-override"
else
  # Existing inline Swift performance evaluator remains byte-for-byte here.
fi
```

Keep Slice 0, Swift tests, both app builds, all six negative controls, all six
positive scenes, artifact checks, structural checks, and hygiene checks
unconditional. In skip mode replace only the final full-gate line with:

```text
SLICE1 FUNCTIONAL GATE PASS
```

Normal mode retains `SLICE1 AUTOMATED GATE PASS` and all existing budgets.

- [ ] **Step 3: Run the functional gate**

Run:

```bash
PATTERN_SKIP_PERFORMANCE=1 ./scripts/verify-slice1.sh
```

Expected final line:

```text
SLICE1 FUNCTIONAL GATE PASS
```

- [ ] **Step 4: Confirm normal mode still enforces performance**

Run:

```bash
./scripts/verify-slice1.sh
```

Expected on the current paravirtual environment: nonzero exit from the existing
unchanged performance budget check after all functional stages pass. If it
passes on stable hardware, preserve that accepted baseline as described in
Task 10.

- [ ] **Step 5: Review and commit**

Review that the flag guards only performance evaluation. Then:

```bash
git add scripts/verify-slice1.sh
git commit -m "ci: allow Slice 1 functional gate"
```

---

### Task 1: Finite Affine And Convex Geometry

**Files:**
- Create: `Sources/PatternEngine/Affine2D.swift`
- Create: `Sources/PatternEngine/ConvexGeometry.swift`
- Create: `Tests/PatternEngineTests/Affine2DTests.swift`
- Create: `Tests/PatternEngineTests/ConvexGeometryTests.swift`

**Interfaces:**

```swift
public struct Affine2D: Equatable, Sendable {
    public let xAxis: SIMD2<Float>
    public let yAxis: SIMD2<Float>
    public let translation: SIMD2<Float>

    public init(
        xAxis: SIMD2<Float>,
        yAxis: SIMD2<Float>,
        translation: SIMD2<Float>
    )
    public static let identity: Affine2D
    public func applying(to point: SIMD2<Float>) -> SIMD2<Float>
    public func concatenating(_ next: Affine2D) -> Affine2D
    public func inverted() -> Affine2D
}

public struct AxisAlignedRect: Equatable, Sendable {
    public let minimum: SIMD2<Float>
    public let maximum: SIMD2<Float>

    public init(minimum: SIMD2<Float>, maximum: SIMD2<Float>)
    public var corners: [SIMD2<Float>] { get }
    public func intersects(_ other: AxisAlignedRect) -> Bool
    public func transformed(by affine: Affine2D) -> AxisAlignedRect
}

public struct HalfPlane2D: Equatable, Sendable {
    public let normal: SIMD2<Float>
    public let offset: Float
    public init(normal: SIMD2<Float>, offset: Float)
    public func contains(_ point: SIMD2<Float>, tolerance: Float) -> Bool
}

public struct ConvexClip: Equatable, Sendable {
    public let halfPlanes: [HalfPlane2D]
    public init(halfPlanes: [HalfPlane2D])
    public func contains(_ point: SIMD2<Float>, tolerance: Float) -> Bool
}
```

- [ ] **Step 1: Write failing affine round-trip and composition tests**

Create `Tests/PatternEngineTests/Affine2DTests.swift` with:

```swift
import PatternEngine
import simd
import Testing

@Test
func mixedAxisReflectionRoundTrips() {
    let affine = Affine2D(
        xAxis: SIMD2(-1, 0),
        yAxis: SIMD2(0, 1),
        translation: SIMD2(256, 17)
    )
    let point = SIMD2<Float>(33, -4)
    let roundTrip = affine.inverted().applying(
        to: affine.applying(to: point)
    )
    #expect(simd_distance(roundTrip, point) < 0.0001)
}

@Test
func concatenationAppliesBrushThenCellTransform() {
    let brushToWorld = Affine2D(
        xAxis: SIMD2(0, 2),
        yAxis: SIMD2(-2, 0),
        translation: SIMD2(300, 144)
    )
    let worldToCanonical = Affine2D(
        xAxis: SIMD2(1, 0),
        yAxis: SIMD2(0, 1),
        translation: SIMD2(-288, -144)
    )
    let combined = brushToWorld.concatenating(worldToCanonical)
    #expect(
        simd_distance(
            combined.applying(to: SIMD2<Float>(1, 0)),
            SIMD2<Float>(12, 2)
        ) < 0.0001
    )
}
```

- [ ] **Step 2: Write failing half-open bounds and clip tests**

Create `Tests/PatternEngineTests/ConvexGeometryTests.swift` with exact tests
for:

```swift
let unit = AxisAlignedRect(
    minimum: SIMD2<Float>(0, 0),
    maximum: SIMD2<Float>(1, 1)
)
#expect(unit.intersects(
    AxisAlignedRect(
        minimum: SIMD2<Float>(0.5, 0.5),
        maximum: SIMD2<Float>(2, 2)
    )
))
#expect(!unit.intersects(
    AxisAlignedRect(
        minimum: SIMD2<Float>(1, 0),
        maximum: SIMD2<Float>(2, 1)
    )
))

let clip = ConvexClip(halfPlanes: [
    HalfPlane2D(normal: SIMD2(1, 0), offset: 0),
    HalfPlane2D(normal: SIMD2(-1, 0), offset: -1),
    HalfPlane2D(normal: SIMD2(0, 1), offset: 0),
    HalfPlane2D(normal: SIMD2(0, -1), offset: -1),
])
#expect(clip.contains(SIMD2<Float>(0.5, 0.5), tolerance: 0))
#expect(!clip.contains(SIMD2<Float>(1.01, 0.5), tolerance: 0))
```

Also assert construction traps in a subprocess for a fifth plane, a zero
normal, a non-normalized normal, a singular affine inverse, and non-finite
bounds.

- [ ] **Step 3: Run the focused tests and confirm missing-type failures**

Run:

```bash
swift test --filter Affine2DTests
swift test --filter ConvexGeometryTests
```

Expected: compile failures naming the missing types.

- [ ] **Step 4: Implement `Affine2D`**

Use column-vector math:

```swift
public func applying(to point: SIMD2<Float>) -> SIMD2<Float> {
    xAxis * point.x + yAxis * point.y + translation
}

public func concatenating(_ next: Affine2D) -> Affine2D {
    Affine2D(
        xAxis: next.xAxis * xAxis.x + next.yAxis * xAxis.y,
        yAxis: next.xAxis * yAxis.x + next.yAxis * yAxis.y,
        translation: next.applying(to: translation)
    )
}
```

Compute the inverse from the 2x2 determinant and translated inverse. Validate
every component is finite and reject a determinant whose magnitude is below
`Float.ulpOfOne`.

- [ ] **Step 5: Implement half-open bounds and validated clips**

`AxisAlignedRect.intersects` must use strict overlap on both axes so touching
right/bottom edges do not intersect. Normalize neither invalid half-planes nor
zero normals silently; construction is a programmer precondition. Accept
plane distances within `0.0001` of unit length.

- [ ] **Step 6: Run focused tests, the full suite, and dependency audit**

Run:

```bash
swift test --filter Affine2DTests
swift test --filter ConvexGeometryTests
swift test
! rg -n 'import (Metal|MetalKit|SwiftUI|AppKit|UIKit|Observation)' \
  Sources/PatternEngine
```

Expected: all pass; dependency audit prints nothing.

- [ ] **Step 7: Review and commit**

Review the diff against spec sections 3 and 5.1. After reviewer approval:

```bash
git add Sources/PatternEngine/Affine2D.swift \
  Sources/PatternEngine/ConvexGeometry.swift \
  Tests/PatternEngineTests/Affine2DTests.swift \
  Tests/PatternEngineTests/ConvexGeometryTests.swift
git commit -m "feat: add finite affine geometry"
```

---

### Task 2: Seven Tiling Definitions And Finite Images

**Files:**
- Create: `Sources/PatternEngine/TilingKind.swift`
- Create: `Sources/PatternEngine/TilingStrategy.swift`
- Create: `Tests/PatternEngineTests/TilingStrategyTests.swift`
- Keep temporarily: `Sources/PatternEngine/GridProjection.swift`

**Interfaces:**

```swift
public enum TilingKind: UInt32, CaseIterable, Codable, Sendable {
    case grid = 0
    case halfDrop = 1
    case brick = 2
    case mirrorX = 3
    case mirrorY = 4
    case mirrorXY = 5
    case rotational = 6
}

public struct CellIndex: Hashable, Sendable {
    public let column: Int
    public let row: Int
    public init(column: Int, row: Int)
}

public struct TilingImage: Equatable, Sendable {
    public let cell: CellIndex
    public let ordinal: UInt8
    public let worldBounds: AxisAlignedRect
    public let worldToCanonical: Affine2D
    public init(
        cell: CellIndex,
        ordinal: UInt8,
        worldBounds: AxisAlignedRect,
        worldToCanonical: Affine2D
    )
}

public struct TilingStrategy: Equatable, Sendable {
    public let kind: TilingKind
    public let tileSize: PatternSize

    public init(kind: TilingKind, tileSize: PatternSize)
    public func cell(containing point: WorldPoint) -> CellIndex
    public func images(intersecting bounds: AxisAlignedRect) -> [TilingImage]
    public func displayFold(_ point: WorldPoint) -> CanonicalPoint
}
```

- [ ] **Step 1: Write the failing raw-value and fold table**

Create one table-driven test with these exact probes for a `288 x 192` tile:

```swift
let probes: [(TilingKind, WorldPoint, CanonicalPoint)] = [
    (.grid,      .init(x: -1,  y: 193), .init(x: 287, y: 1)),
    (.halfDrop,  .init(x: 300, y: 96),  .init(x: 12,  y: 0)),
    (.brick,     .init(x: 144, y: 200), .init(x: 0,   y: 8)),
    (.mirrorX,   .init(x: 300, y: 20),  .init(x: 276, y: 20)),
    (.mirrorY,   .init(x: 20,  y: 200), .init(x: 20,  y: 184)),
    (.mirrorXY,  .init(x: 300, y: 200), .init(x: 276, y: 184)),
    (.rotational,.init(x: 300, y: 200), .init(x: 12,  y: 8)),
]
```

Assert raw values are exactly `Array(0...6).map(UInt32.init)`. Add exact
right/bottom boundary, negative parity, and indices near `+/-1_000_000` for
every family. In subprocess precondition tests, reject strategy tile widths or
heights that are non-finite, fractional, below `64`, or above `4096`; accept
the exact `64` and `4096` boundaries independently.

- [ ] **Step 2: Write failing image-transform tests**

Assert:

- grid cell `(-1, 2)` maps its origin to canonical zero;
- half-drop odd column origin is `(column * width, row * height + height/2)`;
- brick odd row origin is `(column * width + width/2, row * height)`;
- mirror X/Y/XY axes are exactly `diag(-1,1)`, `diag(1,-1)`, and
  `diag(-1,-1)` in odd cells;
- rotational cells expose ordinal `0` identity and ordinal `1` with basis
  `diag(-1,-1)` around `(width/2,height/2)`;
- every returned image strictly intersects the requested bounds;
- image order is row, column, ordinal and is stable across two calls.

- [ ] **Step 3: Run the focused tests and confirm missing-type failures**

Run:

```bash
swift test --filter TilingStrategyTests
```

Expected: compile failure naming `TilingKind` and `TilingStrategy`.

- [ ] **Step 4: Implement positive half-open fold and cell formulas**

Use one private positive modulo helper:

```swift
private func positiveModulo(_ value: Float, _ extent: Float) -> Float {
    let remainder = value.truncatingRemainder(dividingBy: extent)
    if remainder == 0 { return 0 }
    if remainder < 0 { return min(remainder + extent, extent.nextDown) }
    return remainder
}
```

For half-drop, determine column before row:

```swift
let column = Int(floor(point.x / width))
let phaseY = parity(column) * height * 0.5
let row = Int(floor((point.y - phaseY) / height))
```

Brick is the exact transpose. Mirror uses grid indices and reflected local
coordinates. Rotational display uses the translation fold because projection
stores the identity plus tile-center-rotated group image; do not invent a
checkerboard parity formula.

`TilingStrategy.init(kind:tileSize:)` preconditions that both dimensions are
finite integers in `64...4096`:

```swift
precondition(tileSize.width.isFinite && tileSize.height.isFinite)
precondition(tileSize.width.rounded(.towardZero) == tileSize.width)
precondition(tileSize.height.rounded(.towardZero) == tileSize.height)
precondition((64...4096).contains(Int(tileSize.width)))
precondition((64...4096).contains(Int(tileSize.height)))
```

- [ ] **Step 5: Implement bounded image enumeration**

Enumerate integer columns first. For half-drop, derive each column's phased row
range separately; for brick, derive each row's phased column range separately.
Mirror returns one image per cell. Rotational returns two images per
translation cell and removes only byte-for-byte duplicate `TilingImage`
values while preserving ordinal order. Strategy-level image equality does not
claim p2 fixed-point coverage equality: Task 3 performs the operational,
coverage-symmetry-aware deduplication after clipping.

- [ ] **Step 6: Run boundary/property tests and full CPU tests**

Run:

```bash
swift test --filter TilingStrategyTests
swift test
```

Expected: all pass, including existing `GridProjectionTests`.

- [ ] **Step 7: Review and commit**

Review against spec sections 3, 4, and 5.2. Explicitly reject any p2
checkerboard implementation. After approval:

```bash
git add Sources/PatternEngine/TilingKind.swift \
  Sources/PatternEngine/TilingStrategy.swift \
  Tests/PatternEngineTests/TilingStrategyTests.swift
git commit -m "feat: define generalized tiling images"
```

---

### Task 3: Oriented Footprints And Cell-Fragment Projection

**Files:**
- Create: `Sources/PatternEngine/StampFootprint.swift`
- Create: `Sources/PatternEngine/TilingProjection.swift`
- Create: `Tests/PatternEngineTests/TilingProjectionTests.swift`
- Delete after migration: `Sources/PatternEngine/GridProjection.swift`
- Delete after migration: `Tests/PatternEngineTests/GridProjectionTests.swift`

**Interfaces:**

```swift
public enum FootprintCoverageSymmetry: UInt8, Equatable, Sendable {
    case oriented
    case halfTurnInvariant
}

public struct StampFootprint: Equatable, Sendable {
    public let brushToWorld: Affine2D
    public let localBounds: AxisAlignedRect
    public let coverageSymmetry: FootprintCoverageSymmetry
    public init(
        brushToWorld: Affine2D,
        localBounds: AxisAlignedRect,
        coverageSymmetry: FootprintCoverageSymmetry
    )
}

public struct CellFragment: Equatable, Sendable {
    public let cell: CellIndex
    public let imageOrdinal: UInt8
    public let canonicalFromBrush: Affine2D
    public let brushClip: ConvexClip
    public init(
        cell: CellIndex,
        imageOrdinal: UInt8,
        canonicalFromBrush: Affine2D,
        brushClip: ConvexClip
    )
}

public enum TilingProjection {
    public static func clampedRadius(
        requested: Float,
        tileSize: PatternSize
    ) -> Float

    public static func fragments(
        for footprint: StampFootprint,
        using strategy: TilingStrategy
    ) -> [CellFragment]
}
```

- [ ] **Step 1: Write failing grid edge/corner fragment tests**

For a radius-10 footprint centered at `(3,3)` in a `256 x 256` grid, use
normalized local bounds `[-1,1] x [-1,1]` and brush-to-world axes
`(10,0)`/`(0,10)` with `.halfTurnInvariant` coverage. Assert four fragments
with four-plane clips and canonical translations covering the central,
right-wrap, bottom-wrap, and corner-wrap pieces. Rasterize integer probe points
through the fragments in test code and assert no point is covered twice after
owning-cell clips.

- [ ] **Step 2: Write failing transformed and bounded-enumeration tests**

Add:

- half-drop `(300,144)` in `288 x 288` produces complementary phased clips
  with no full phantom disk;
- brick is the exact transposed fragment set;
- mirror XY preserves both negative basis axes;
- an asymmetric rotated footprint preserves one continuous brush-local point
  on both sides of a seam;
- a rotated footprint whose AABB overlaps a cell only at an empty corner emits
  no fragment after exact convex intersection;
- a p2 hard-round footprint at the tile center uses `.halfTurnInvariant` and
  emits one coverage-equivalent fixed-point fragment;
- the same centered p2 footprint marked `.oriented` emits both opposite
  brush-local orientations;
- requested radius `10_000` on `64 x 96` clamps to `256`;
- radius `1` is accepted as the exact minimum and any smaller radius is
  rejected before projection;
- the clamped maximum footprint enumerates no more than 81 translation cells
  before rotational ordinals;
- repeated calls produce byte-for-byte identical order.

- [ ] **Step 3: Run the focused tests and confirm missing projector failures**

Run:

```bash
swift test --filter TilingProjectionTests
```

Expected: compile failure naming `StampFootprint`, `CellFragment`, and
`TilingProjection`.

- [ ] **Step 4: Implement footprint bounds and canonical composition**

Transform all four local corners to world, compute their conservative bounds,
request intersecting images, and compose:

```swift
let canonicalFromBrush =
    footprint.brushToWorld.concatenating(image.worldToCanonical)
```

Do not fold only the center.

- [ ] **Step 5: Map cell boundaries into brush-local half-planes**

For a world-cell plane `dot(worldNormal, world) >= worldOffset` and
`world = A * brushLocal + translation`, compute:

```swift
let localNormalUnscaled = SIMD2<Float>(
    simd_dot(worldNormal, footprint.brushToWorld.xAxis),
    simd_dot(worldNormal, footprint.brushToWorld.yAxis)
)
let localOffsetUnscaled =
    worldOffset - simd_dot(
        worldNormal,
        footprint.brushToWorld.translation
    )
let length = simd_length(localNormalUnscaled)
let localNormal = localNormalUnscaled / length
let localOffset = localOffsetUnscaled / length
```

Clip the transformed footprint quad against the world-cell rectangle with
Sutherland-Hodgman, and emit only when the resulting convex polygon has at
least three vertices and absolute shoelace area greater than `0.0001`.
Reject zero/non-finite lengths and nonintersecting AABBs before this exact
intersection. Emit no more than four planes.

- [ ] **Step 6: Deduplicate coverage-equivalent p2 fixed images and sort**

First remove byte-for-byte equal fragments. For
`.halfTurnInvariant` footprints only, create a `CoverageDomainKey` from:

1. canonical center and the lengths of both canonical affine axes;
2. the Sutherland-Hodgman local clip polygon transformed to canonical space;
3. canonical polygon vertices normalized for `-0`, rotated to start at the
   lexicographically smallest vertex, and made winding-independent.

Deduplicate equal keys so a hard-round stamp at a p2 fixed point is blended
once. For `.oriented`, keep identity and rotated fragments even when their
centers match, because asymmetric shape and coordinate output depend on
orientation. Sort remaining fragments by row, column, ordinal, then all six
affine scalars and clip scalars.

- [ ] **Step 7: Replace the old grid tests with generalized regressions**

Move every existing grid fold/edge/corner/tangent assertion into
`TilingStrategyTests.swift` or `TilingProjectionTests.swift`, then delete
`GridProjection.swift` and `GridProjectionTests.swift`. Verify:

```bash
! rg -n 'GridProjection|CanonicalDabPlacement' Sources Tests
```

- [ ] **Step 8: Run focused/full tests, review, and commit**

Run:

```bash
swift test --filter TilingProjectionTests
swift test
```

Review against spec sections 5.3 through 5.5 and the recovered half-drop
phantom evidence. After approval:

```bash
git add Sources/PatternEngine/StampFootprint.swift \
  Sources/PatternEngine/TilingProjection.swift \
  Sources/PatternEngine/TilingStrategy.swift \
  Sources/PatternEngine/GridProjection.swift \
  Tests/PatternEngineTests/TilingStrategyTests.swift \
  Tests/PatternEngineTests/TilingProjectionTests.swift \
  Tests/PatternEngineTests/GridProjectionTests.swift
git commit -m "feat: project clipped cell fragments"
```

---

### Task 4: Independent Pixel Coverage Oracle

**Files:**
- Create:
  `Sources/PatternEngine/Verification/TilingCoverageOracle.swift`
- Create:
  `Tests/PatternEngineTests/TilingCoverageOracleTests.swift`

**Interfaces:**

```swift
public enum OracleFootprint: Equatable, Sendable {
    case hardRound(radius: Float)
    case asymmetricTriangle
}

public struct OracleCoverage: Equatable, Sendable {
    public let pixelSize: PixelSize
    public let bytes: [UInt8]
    public init(pixelSize: PixelSize, bytes: [UInt8])
}

public struct OracleRasterResult: Equatable, Sendable {
    public let coverage: OracleCoverage
    public let canonicalCoordinatesBGRA: [UInt8]
    public let brushLocalCoordinatesBGRA: [UInt8]
    public init(
        coverage: OracleCoverage,
        canonicalCoordinatesBGRA: [UInt8],
        brushLocalCoordinatesBGRA: [UInt8]
    )
}

public struct CoverageComparison: Equatable, Sendable {
    public let holeCount: Int
    public let phantomCount: Int
    public let maximumDelta: UInt8
    public init(
        holeCount: Int,
        phantomCount: Int,
        maximumDelta: UInt8
    )
}

public enum TilingCoverageOracle {
    public static func renderCanonical(
        footprint: OracleFootprint,
        brushToWorld: Affine2D,
        tileSize: PixelSize,
        tiling: TilingKind,
        supersampling: Int
    ) -> OracleRasterResult

    public static func compare(
        expected: OracleCoverage,
        actual: OracleCoverage,
        boundaryTolerance: UInt8
    ) -> CoverageComparison
}
```

The asymmetric triangle is fixed at brush-local vertices
`(-0.75,-0.60)`, `(0.85,-0.20)`, and `(-0.10,0.90)`.

- [ ] **Step 1: Write failing direct-fold and comparison tests**

Add table-driven exact integer probes for all seven kinds, including:

- negative and large coordinates;
- half-drop/brick parity changes;
- all mirror axis combinations;
- p2 translation and tile-center rotation generators;
- a p2 fixed-point sample that is written once;
- rectangular `64 x 96` output;
- independently encoded canonical and brush-local coordinate bytes;
- comparison counts one injected hole and one injected phantom.

- [ ] **Step 2: Add the production-versus-oracle property matrix**

In test-only code, rasterize `TilingProjection.fragments` without calling the
oracle internals. Test hard-round and asymmetric footprints at interior,
edge, corner, noncentral, rotated, reflected, large, and rectangular cases.
Require:

```swift
#expect(comparison.holeCount == 0)
#expect(comparison.phantomCount == 0)
#expect(comparison.maximumDelta <= 1)
```

- [ ] **Step 3: Run the focused tests and confirm missing-oracle failures**

Run:

```bash
swift test --filter TilingCoverageOracleTests
```

Expected: compile failure naming the oracle API.

- [ ] **Step 4: Implement the oracle with its own tiling switch**

For each deterministic supersample:

1. transform brush-local sample to world;
2. evaluate hard-round or triangle coverage;
3. execute a private direct fold `switch tiling`;
4. for rotational, emit identity and `R(x,y)=(width-x,height-y)` destinations
   and remove equal fixed-point destinations;
5. accumulate coverage plus normalized canonical and uninterrupted brush-local
   coordinates in stable row-major order.

Do not instantiate `TilingStrategy`, request images, construct clips, or call
`TilingProjection`.

- [ ] **Step 5: Prove source-level independence**

Run:

```bash
! rg -n 'TilingStrategy|TilingProjection|CellFragment|TilingImage' \
  Sources/PatternEngine/Verification
```

Expected: no matches.

- [ ] **Step 6: Run the property matrix and full suite**

Run:

```bash
swift test --filter TilingCoverageOracleTests
swift test
```

Expected: zero holes and zero phantoms for the fixed matrix; all tests pass.

- [ ] **Step 7: Review and commit**

Review the oracle and production projector side by side specifically for
accidental helper reuse. After approval:

```bash
git add Sources/PatternEngine/Verification \
  Tests/PatternEngineTests/TilingCoverageOracleTests.swift
git commit -m "test: add independent tiling oracle"
```

---

### Task 5: Exact ABI And Generalized Grid Through Metal

**Files:**
- Modify: `Sources/CShaderTypes/include/ShaderTypes.h`
- Modify: `Sources/MetalRenderer/ShaderABI.swift`
- Create: `Sources/MetalRenderer/ProjectedStampInstance.swift`
- Modify: `Sources/MetalRenderer/LiveStroke.swift`
- Modify: `Sources/MetalRenderer/DabInstanceBufferPool.swift`
- Modify: `Sources/MetalRenderer/GridCanvasContract.swift`
- Modify: `Sources/MetalRenderer/MetalRendererError.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/GridPipelineLibrary.swift`
- Modify: `Sources/MetalRenderer/Shaders.metal`
- Modify: `Tests/MetalRendererTests/ShaderABILayoutTests.swift`
- Create: `Tests/MetalRendererTests/ProjectedStampInstanceTests.swift`
- Modify: `Tests/MetalRendererTests/LiveStrokeTests.swift`

- [ ] **Step 1: Write failing exact-layout tests**

Assert:

```swift
#expect(MemoryLayout<PatternClipHalfPlane>.size == 16)
#expect(MemoryLayout<PatternClipHalfPlane>.stride == 16)
#expect(MemoryLayout<PatternProjectedStampInstance>.size == 96)
#expect(MemoryLayout<PatternProjectedStampInstance>.stride == 96)
#expect(MemoryLayout<PatternProjectedStampInstance>.alignment == 8)
#expect(MemoryLayout<PatternProjectedStampInstance>.offset(
    of: \.canonicalXAxis
) == 0)
#expect(MemoryLayout<PatternProjectedStampInstance>.offset(
    of: \.canonicalYAxis
) == 8)
#expect(MemoryLayout<PatternProjectedStampInstance>.offset(
    of: \.canonicalTranslation
) == 16)
#expect(MemoryLayout<PatternProjectedStampInstance>.offset(
    of: \.radius
) == 24)
#expect(MemoryLayout<PatternProjectedStampInstance>.offset(
    of: \.clipCount
) == 28)
#expect(MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clip0) == 32)
#expect(MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clip1) == 48)
#expect(MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clip2) == 64)
#expect(MemoryLayout<PatternProjectedStampInstance>.offset(of: \.clip3) == 80)
#expect(MemoryLayout<PatternGridFrameUniforms>.size == 48)
#expect(MemoryLayout<PatternGridFrameUniforms>.stride == 48)
#expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.tilingKind) == 40)
#expect(
    MemoryLayout<PatternGridFrameUniforms>.offset(of: \.diagnosticMode) == 44
)
```

Retain exact assertions for tiling wire values `0...6`, existing buffer index
`2`, texture indices `0...1`, and append diagnostic values `0...3` for none,
asymmetric coverage, canonical coordinates, and brush-local coordinates.

- [ ] **Step 2: Write failing packing tests**

Given a reflected `CellFragment` with two planes, assert
`PatternProjectedStampInstance(fragment:radius:)` copies all affine scalars,
sets `clipCount == 2`, zero-fills clips 2 and 3, and rejects radius outside
the approved clamp.

- [ ] **Step 3: Run focused tests and confirm missing ABI failures**

Run:

```bash
swift test --filter ShaderABILayoutTests
swift test --filter ProjectedStampInstanceTests
```

Expected: compile failures for the new C types and initializer.

- [ ] **Step 4: Replace the shared instance layout**

Use this exact C/MSL declaration:

```c
typedef struct PatternClipHalfPlane {
    PatternFloat2 normal;
    float offset;
    float padding;
} PatternClipHalfPlane;

typedef struct PatternProjectedStampInstance {
    PatternFloat2 canonicalXAxis;
    PatternFloat2 canonicalYAxis;
    PatternFloat2 canonicalTranslation;
    float radius;
    PatternUInt32 clipCount;
    PatternClipHalfPlane clip0;
    PatternClipHalfPlane clip1;
    PatternClipHalfPlane clip2;
    PatternClipHalfPlane clip3;
} PatternProjectedStampInstance;
```

Append `PatternUInt32 tilingKind` and `PatternUInt32 diagnosticMode` to
`PatternGridFrameUniforms`, making its size/stride `48`, without moving prior
fields. Keep `PatternBufferIndexDabInstances == 2`. Append shared
`PatternDiagnosticWireNone == 0`,
`PatternDiagnosticWireAsymmetricCoverage == 1`,
`PatternDiagnosticWireCanonicalCoordinates == 2`, and
`PatternDiagnosticWireBrushLocalCoordinates == 3`.

- [ ] **Step 5: Update runtime ABI validation and packing**

Add every size, stride, alignment, and offset assertion to
`ShaderABI.isValid`. Map `CellFragment` into the C struct in one initializer.
Zero-fill inactive planes deterministically.

- [ ] **Step 6: Move live storage and buffer uploads to projected instances**

Change `IdentifiedDab.instance`, `LiveStroke.append`, buffer allocation,
capacity calculation, binding, and writes from `PatternDabInstance` to
`PatternProjectedStampInstance`. Keep absolute identity, fixed pending
capacity, triple buffering, and nonblocking leases unchanged. Replace
dab-specific exhaustion reporting with
`.projectedInstanceCapacityExceeded(capacity)`; a dropped fragment is never
reported as success.

- [ ] **Step 7: Implement the generalized production vertex/fragment**

The vertex must emit canonical and normalized brush-local coordinates.
`canonicalXAxis` and `canonicalYAxis` already include radius, rotation, and
reflection. Expand the normalized quad by one canonical pixel:

```metal
const float normalizedExpansion = 1.0 + 1.0 / instance.radius;
const float2 brushLocal = corners[vertexID] * normalizedExpansion;
const float2 canonical =
    instance.canonicalTranslation
    + instance.canonicalXAxis * brushLocal.x
    + instance.canonicalYAxis * brushLocal.y;
```

The fragment tests each active half-plane before applying the unchanged
hard-round equation:

```metal
const float2 offsetPixels = input.brushLocal * input.radius;
const float coverage = clamp(
    input.radius + 0.5 - length(offsetPixels),
    0.0,
    1.0
);
```

Keep straight-alpha stamp blend factors and commit source-over math unchanged.

- [ ] **Step 8: Route interactive grid dabs through `TilingProjection`**

Construct one normalized `[-1,1] x [-1,1]` footprint at each interpolated
world point, with radius-10 brush-to-world axes `(10,0)`/`(0,10)` and
`.halfTurnInvariant` coverage. Project it through
`TilingStrategy(kind:.grid, tileSize:tileSize)`, pack each fragment, and append
it. Diagnostic triangle and coordinate footprints use `.oriented`. Remove
every production call to `GridProjection`. Generalize the renderer initializer
to accept immutable `PixelSize`, defaulting to `256 x 256`; create all three
textures with independent width and height.

- [ ] **Step 9: Run CPU gates, both builds, and the real-metallib grid scenes**

Run:

```bash
swift test
(cd App && xcodegen generate)
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac -configuration Debug build
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
PATTERN_SKIP_PERFORMANCE=1 ./scripts/verify-slice1.sh
```

Expected: all current Slice 0/1 negative controls fail for their recorded
reason, all positives pass, and final line is
`SLICE1 FUNCTIONAL GATE PASS`.

- [ ] **Step 10: Review and commit**

Review the 96-byte ABI, clip sign convention, buffer capacity bytes, shader
blend factors, and absence of a grid-only projector. After approval:

```bash
git add Sources/CShaderTypes/include/ShaderTypes.h \
  Sources/MetalRenderer/ShaderABI.swift \
  Sources/MetalRenderer/ProjectedStampInstance.swift \
  Sources/MetalRenderer/LiveStroke.swift \
  Sources/MetalRenderer/DabInstanceBufferPool.swift \
  Sources/MetalRenderer/GridCanvasContract.swift \
  Sources/MetalRenderer/MetalRendererError.swift \
  Sources/MetalRenderer/GridRenderer.swift \
  Sources/MetalRenderer/GridPipelineLibrary.swift \
  Sources/MetalRenderer/Shaders.metal \
  Tests/MetalRendererTests/ShaderABILayoutTests.swift \
  Tests/MetalRendererTests/ProjectedStampInstanceTests.swift \
  Tests/MetalRendererTests/LiveStrokeTests.swift
git commit -m "feat: stamp projected fragments in Metal"
```

---

### Task 6: Translation Tilings, Harness Schema 3, And Oracle Artifacts

**Files:**
- Modify: `Sources/MetalRenderer/Shaders.metal`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/Capture/HarnessScene.swift`
- Modify: `Sources/MetalRenderer/Capture/HarnessRunner.swift`
- Modify: `Sources/MetalRenderer/Capture/PNGWriter.swift`
- Modify: `Tests/MetalRendererTests/HarnessSceneTests.swift`
- Create the generalized-grid, half-drop, and brick scene pairs from File Map

**Schema 3 additions:**

```swift
public enum HarnessDiagnosticMode: String, Codable, Sendable {
    case hardRound
    case asymmetricCoverage
    case canonicalCoordinates
    case brushLocalCoordinates
}

public enum TilingHarnessProgram: String, Codable, Sendable {
    // Keep the six schema-2 raw values unchanged.
    case gridInterior, gridBoundary, previewCommit
    case cancelPreservesCanonical, fiveHundredDabs, longStroke
    // Append Slice 2 programs.
    case generalizedGrid
    case halfDropInterior, halfDropEdge, halfDropCorner
    case brickTranspose
    case mirrorX, mirrorY, mirrorXY
    case rotationalGenerator, rotationalFixedPoint, rotationalOrientation
    case largeFootprint, asymmetricFootprint
    case canonicalCoordinateContinuity, brushLocalCoordinateContinuity
    case rectangularTile, noncentralVisibleCell, metadataTilingSwitch
    case projectedLiveCommit, projectedLongStroke
}

public struct HarnessScene: Codable, Equatable, Sendable {
    // Existing schema 1/2 fields retain their types and coding keys.
    public let schemaVersion: Int
    public let name: String
    public let width: Int
    public let height: Int
    public let checks: [HarnessPixelCheck]
    public let program: TilingHarnessProgram?
    public let structuralChecks: [HarnessStructuralCheck]

    // Schema 3 fields. They are nil only after decoding schema 1/2.
    public let tileWidth: Int?
    public let tileHeight: Int?
    public let tiling: TilingKind?
    public let diagnosticMode: HarnessDiagnosticMode?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, name, width, height, checks, program
        case structuralChecks, tileWidth, tileHeight, tiling
        case diagnosticMode
    }
}
```

Schema 3 requires `tileWidth`, `tileHeight`, `tiling`, and `diagnosticMode`.
`tiling` encodes the append-only numeric wire value `0...6`;
`diagnosticMode` encodes its string raw value. Oracle assertions use the
existing `structuralChecks` array with appended metric raw strings; there is no
second assertion container. Schema 1/2 decoding resolves nil fields to
`256 x 256`, grid, and hard-round at the runner boundary, while schema 1/2
encoding omits all four new keys and stays byte-shape compatible.

Append these exact structural metric raw strings:

```swift
case oracleHoleCount
case oraclePhantomCount
case oracleMaximumDelta
case restoredDisplayMaximumDelta
case transformMismatchCount
case duplicateFixedPointWriteCount
case coordinateContinuityMismatchCount
case visibleCellCanonicalByteDelta
case previewCommitViolationCount
```

Use this exact schema-3 fixture shape for
`halfdrop-edge.json`:

```json
{
  "schemaVersion": 3,
  "name": "halfdrop-edge",
  "width": 512,
  "height": 512,
  "tileWidth": 288,
  "tileHeight": 192,
  "tiling": 1,
  "diagnosticMode": "hardRound",
  "program": "halfDropEdge",
  "checks": [
    {
      "channel": "canonical",
      "x": 0,
      "y": 0,
      "expectedBGRA": [0, 0, 0, 255],
      "tolerance": 1
    }
  ],
  "structuralChecks": [
    {
      "metric": "oracleHoleCount",
      "relation": "equal",
      "value": 0
    },
    {
      "metric": "oraclePhantomCount",
      "relation": "equal",
      "value": 0
    },
    {
      "metric": "oracleMaximumDelta",
      "relation": "lessThanOrEqual",
      "value": 1
    }
  ]
}
```

Its negative control is byte-for-byte identical except name
`halfdrop-edge-negative-control` and `oracleHoleCount.value == 1`. With the
correct renderer it must print exactly:

```text
HARNESS FAIL Tiling scene 'halfdrop-edge-negative-control' tiling halfDrop cell none metric oracleHoleCount: expected equal 1, actual 0.
```

- [ ] **Step 1: Write failing schema-compatibility tests**

Decode all existing scene files unchanged. Decode one schema-3 `64 x 96`
half-drop scene. Reject tile dimensions outside `64...4096`, a scene tiling
that disagrees with its fixed program, an interactive diagnostic mode other
than `hardRound`, missing required schema-3 keys, a numeric tiling outside
`0...6`, and missing assertions. Re-encode schema 1/2 fixtures and assert none
of the four schema-3 coding keys appear.

- [ ] **Step 2: Add typed oracle mismatch reporting**

Append every schema-3 structural metric listed above. Add a typed error
containing scene, tiling, cell, channel, coordinate, expected, actual, and
tolerance. Add `.oracleCoverage`, `.oracleCanonicalCoordinates`, and
`.oracleBrushLocalCoordinates` as artifact channels without changing old raw
strings.

The exact structural-error format is:

```text
HARNESS FAIL Tiling scene '<scene>' tiling <kind> cell <column,row|none> metric <metric>: expected <relation> <expected>, actual <actual>.
```

After the Mac build, use this exact negative-first command helper in Tasks
6 through 9:

```bash
run_pair() {
  name="$1"
  tiling="$2"
  metric="$3"
  binary=".build/DerivedData/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike"
  scenes="App/PatternSpike/Harness/Scenes"
  artifacts=".build/slice2-artifacts"
  negative="$name-negative-control"
  negative_output="$artifacts/negative-control/$negative"
  positive_output="$artifacts/positive/$name"
  mkdir -p "$negative_output" "$positive_output"

  if "$binary" \
    --harness-scene "$scenes/$negative.json" \
    --output-directory "$negative_output" \
    --git-commit "$(git rev-parse HEAD)" \
    --configuration Debug \
    >"$negative_output/stdout.log" \
    2>"$negative_output/stderr.log"
  then
    printf 'Negative control unexpectedly passed: %s\n' "$negative"
    return 1
  fi
  expected="HARNESS FAIL Tiling scene '$negative' tiling $tiling cell none metric $metric: expected equal 1, actual 0."
  grep -Fqx "$expected" "$negative_output/stderr.log"

  "$binary" \
    --harness-scene "$scenes/$name.json" \
    --output-directory "$positive_output" \
    --git-commit "$(git rev-parse HEAD)" \
    --configuration Debug \
    | tee "$positive_output/stdout.log"
  grep -q "^HARNESS PASS scene=$name " "$positive_output/stdout.log"
  test -s "$positive_output/$name.benchmark.json"
}
```

- [ ] **Step 3: Run schema tests and confirm schema-3 failures**

Run:

```bash
swift test --filter HarnessSceneTests
```

Expected: new tests fail before schema implementation and old tests remain
compilable.

- [ ] **Step 4: Implement append-only schema 3**

Use defaults only for legacy schemas. Schema 3 must explicitly encode tile
dimensions and tiling. Canonical coordinate validation must use scene tile
width and height instead of `GridCanvasContract.tileSize`.

- [ ] **Step 5: Add independent oracle PNG/metric capture**

`HarnessRunner` calls `TilingCoverageOracle` only after deterministic harness
input has been fixed. Write oracle coverage and coordinate PNGs, compare them
to the corresponding production captures, and expose
hole/phantom/max-delta metrics. Do not feed oracle bytes back into the
renderer.

- [ ] **Step 6: Implement half-drop and brick display folds in MSL**

Mirror the approved formulas exactly:

```metal
case PatternTilingWireHalfDrop: {
    const int column = int(floor(world.x / tileSize.x));
    const float phaseY = (column & 1) * tileSize.y * 0.5;
    return patternPositiveFold(
        float2(world.x, world.y - phaseY),
        tileSize
    );
}
case PatternTilingWireBrick: {
    const int row = int(floor(world.y / tileSize.y));
    const float phaseX = (row & 1) * tileSize.x * 0.5;
    return patternPositiveFold(
        float2(world.x - phaseX, world.y),
        tileSize
    );
}
```

Use the strategy selected by renderer state for projection and the matching
raw value for display. Compute grid-line distance from the active cell's
phased local coordinates: half-drop offsets horizontal boundaries per column,
and brick offsets vertical boundaries per row. Do not reuse the grid fold's
unphased edge distance.

- [ ] **Step 7: Add and prove the five translation-family negative controls**

Add exact scene pairs:

- `generalized-grid`;
- `halfdrop-interior`;
- `halfdrop-edge`;
- `halfdrop-corner`;
- `brick-transpose`.

Each positive asserts oracle holes `0`, phantoms `0`, max delta `<=1`, plus
one intended live/canonical pixel. The half-drop and brick families also
capture a `showGridLines` frame and probe the phased cell boundaries. Each
negative changes exactly one expected metric or pixel and must exit nonzero
with the recorded typed message.

- [ ] **Step 8: Run focused tests, both builds, and all legacy/new scenes**

Run:

```bash
swift test
(cd App && xcodegen generate)
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac -configuration Debug build
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
PATTERN_SKIP_PERFORMANCE=1 ./scripts/verify-slice1.sh
```

Then run:

```bash
run_pair generalized-grid grid oracleHoleCount
run_pair halfdrop-interior halfDrop oraclePhantomCount
run_pair halfdrop-edge halfDrop oracleHoleCount
run_pair halfdrop-corner halfDrop oraclePhantomCount
run_pair brick-transpose brick transformMismatchCount
```

Expected: five exact intended negative failures, five positive passes, and all
legacy gates remain green.

- [ ] **Step 9: Review and commit**

Review schema compatibility, half-drop phase sign, brick transpose, artifact
independence, and typed failure detail. After approval:

```bash
git add Sources/MetalRenderer/Shaders.metal \
  Sources/MetalRenderer/GridRenderer.swift \
  Sources/MetalRenderer/Capture/HarnessScene.swift \
  Sources/MetalRenderer/Capture/HarnessRunner.swift \
  Sources/MetalRenderer/Capture/PNGWriter.swift \
  Tests/MetalRendererTests/HarnessSceneTests.swift \
  App/PatternSpike/Harness/Scenes/generalized-grid.json \
  App/PatternSpike/Harness/Scenes/generalized-grid-negative-control.json \
  App/PatternSpike/Harness/Scenes/halfdrop-interior.json \
  App/PatternSpike/Harness/Scenes/halfdrop-interior-negative-control.json \
  App/PatternSpike/Harness/Scenes/halfdrop-edge.json \
  App/PatternSpike/Harness/Scenes/halfdrop-edge-negative-control.json \
  App/PatternSpike/Harness/Scenes/halfdrop-corner.json \
  App/PatternSpike/Harness/Scenes/halfdrop-corner-negative-control.json \
  App/PatternSpike/Harness/Scenes/brick-transpose.json \
  App/PatternSpike/Harness/Scenes/brick-transpose-negative-control.json
git commit -m "feat: render phased translation tilings"
```

---

### Task 7: Mirror, Rotational, And Diagnostic Metal Paths

**Files:**
- Modify: `Sources/MetalRenderer/Shaders.metal`
- Modify: `Sources/MetalRenderer/GridPipelineLibrary.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/Capture/HarnessRunner.swift`
- Create mirror, rotational, asymmetric, and coordinate scene pairs from File
  Map

- [ ] **Step 1: Add failing mirror/p2 CPU-to-MSL parity fixtures**

In `TilingStrategyTests.swift`, encode the MSL formulas independently in
test-only functions and compare them to `displayFold` at edges, corners,
negative cells, rectangular sizes, and large indices. Assert p2 translation
and rotation generators; do not assert mirror-style edge continuity for p2.

- [ ] **Step 2: Add the mirror and rotational MSL cases**

Mirror cases alternate by signed cell parity and use positive modulo at exact
boundaries. Rotational display uses the translation fold because the stored
tile is p2-symmetrized by identity and rotated projected images. Unknown wire
values return a fixed debug color in the harness; renderer initialization
rejects unknown values before interactive encoding. Mirror cell lines use the
grid lattice; rotational cell lines use the p2 translation lattice.

- [ ] **Step 3: Add the harness-only diagnostic pipeline**

Create `patternDiagnosticFootprintFragment` paired with the production
projected-stamp vertex. Use the shared `PatternDiagnosticWire*` constants; do
not create a second MSL-only numbering. Modes are fixed:

```metal
PatternDiagnosticWireAsymmetricCoverage == 1
PatternDiagnosticWireCanonicalCoordinates == 2
PatternDiagnosticWireBrushLocalCoordinates == 3
```

- asymmetric coverage evaluates the approved scalene triangle;
- canonical coordinates encode normalized canonical X/Y into red/green;
- brush-local coordinates encode normalized brush-local X/Y into red/green.

Keep the pipeline and selection method internal to harness-only renderer
methods. `ContentView`, `MetalCanvas`, and `InteractiveMetalView` must have no
diagnostic-mode API.

- [ ] **Step 4: Add and prove mirror scene pairs**

Add `mirror-x`, `mirror-y`, and `mirror-xy` pairs. Use the asymmetric
diagnostic so an incorrect sign or axis swap produces a typed orientation
failure. Require zero oracle holes/phantoms.

- [ ] **Step 5: Add and prove rotational scene pairs**

Add `rotational-generator`, `rotational-fixed-point`, and
`rotational-orientation` pairs. Assert:

- `R(x,y)=(width-x,height-y)`;
- translated centers repeat by `(width,0)` and `(0,height)`;
- equal fixed-point samples do not double-write;
- asymmetric orientation is rotated 180 degrees, not mirrored;
- no checkerboard formula is used.

- [ ] **Step 6: Add and prove footprint/coordinate scene pairs**

Add:

- `large-footprint`;
- `asymmetric-footprint`;
- `canonical-coordinate-continuity`;
- `brush-local-coordinate-continuity`.

The large footprint crosses more than immediate neighbors. Coordinate scenes
compare both sides of every crossed fragment seam. Canonical red/green uses
circular 8-bit distance
`min(abs(a-b), 256-abs(a-b)) <= 1`, so the legitimate canonical wrap
`255 -> 0` is continuous modulo the tile. Brush-local red/green uses ordinary
linear distance `abs(a-b) <= 1` and fails if brush-local coordinates restart
per cell.

- [ ] **Step 7: Run the full CPU suite and real-metallib matrix**

Run:

```bash
swift test
(cd App && xcodegen generate)
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac -configuration Debug build
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
```

Run:

```bash
run_pair mirror-x mirrorX transformMismatchCount
run_pair mirror-y mirrorY transformMismatchCount
run_pair mirror-xy mirrorXY transformMismatchCount
run_pair rotational-generator rotational transformMismatchCount
run_pair rotational-fixed-point rotational duplicateFixedPointWriteCount
run_pair rotational-orientation rotational transformMismatchCount
run_pair large-footprint grid oracleHoleCount
run_pair asymmetric-footprint rotational transformMismatchCount
run_pair canonical-coordinate-continuity halfDrop coordinateContinuityMismatchCount
run_pair brush-local-coordinate-continuity mirrorXY coordinateContinuityMismatchCount
PATTERN_SKIP_PERFORMANCE=1 ./scripts/verify-slice1.sh
```

Expected: every negative matches its exact stderr, every positive passes, and
the Slice 1 regression gate remains green.

- [ ] **Step 8: Review and commit**

Review every transform basis, p2 fixed-point behavior, coordinate interpolation,
and diagnostic API visibility. After approval:

```bash
git add Sources/PatternEngine/TilingStrategy.swift \
  Tests/PatternEngineTests/TilingStrategyTests.swift \
  Sources/MetalRenderer/Shaders.metal \
  Sources/MetalRenderer/GridPipelineLibrary.swift \
  Sources/MetalRenderer/GridRenderer.swift \
  Sources/MetalRenderer/Capture/HarnessRunner.swift \
  App/PatternSpike/Harness/Scenes/mirror-x.json \
  App/PatternSpike/Harness/Scenes/mirror-x-negative-control.json \
  App/PatternSpike/Harness/Scenes/mirror-y.json \
  App/PatternSpike/Harness/Scenes/mirror-y-negative-control.json \
  App/PatternSpike/Harness/Scenes/mirror-xy.json \
  App/PatternSpike/Harness/Scenes/mirror-xy-negative-control.json \
  App/PatternSpike/Harness/Scenes/rotational-generator.json \
  App/PatternSpike/Harness/Scenes/rotational-generator-negative-control.json \
  App/PatternSpike/Harness/Scenes/rotational-fixed-point.json \
  App/PatternSpike/Harness/Scenes/rotational-fixed-point-negative-control.json \
  App/PatternSpike/Harness/Scenes/rotational-orientation.json \
  App/PatternSpike/Harness/Scenes/rotational-orientation-negative-control.json \
  App/PatternSpike/Harness/Scenes/large-footprint.json \
  App/PatternSpike/Harness/Scenes/large-footprint-negative-control.json \
  App/PatternSpike/Harness/Scenes/asymmetric-footprint.json \
  App/PatternSpike/Harness/Scenes/asymmetric-footprint-negative-control.json \
  App/PatternSpike/Harness/Scenes/canonical-coordinate-continuity.json \
  App/PatternSpike/Harness/Scenes/canonical-coordinate-continuity-negative-control.json \
  App/PatternSpike/Harness/Scenes/brush-local-coordinate-continuity.json \
  App/PatternSpike/Harness/Scenes/brush-local-coordinate-continuity-negative-control.json
git commit -m "feat: add reflected and rotational tiling"
```

---

### Task 8: Rectangular Resources, Visible-Cell Editing, And Tiling State

**Files:**
- Modify: `Sources/MetalRenderer/GridCanvasContract.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/MetalRendererError.swift`
- Create: `Sources/EditorCore/Model/EditorModel.swift`
- Create: `Tests/EditorCoreTests/EditorModelTests.swift`
- Modify: `App/project.yml`
- Modify: `App/PatternSpike/ContentView.swift`
- Modify: `App/PatternSpike/Canvas/MetalCanvas.swift`
- Modify: `Sources/MetalRenderer/Capture/HarnessRunner.swift`
- Create rectangular, noncentral, switch, live/commit, and long-stroke scene
  pairs from File Map

**State API:**

```swift
@MainActor
@Observable
public final class EditorModel {
    public private(set) var tiling: TilingKind
    public init(tiling: TilingKind = .grid)
    public func confirmTiling(_ tiling: TilingKind)
}

@MainActor
public func setTiling(_ tiling: TilingKind) throws
```

- [ ] **Step 1: Write failing model and renderer-state tests**

Assert `EditorModel` defaults to grid and changes only through
`confirmTiling`. Add a pure lifecycle seam or renderer contract test proving
`setTiling`:

- succeeds when idle;
- rejects active, commit-requested, and commit-pending states with
  `.tilingChangeRequiresIdle`;
- leaves the prior renderer tiling unchanged on rejection.

- [ ] **Step 2: Run focused tests and confirm missing APIs**

Run:

```bash
swift test --filter EditorModelTests
swift test --filter GridCanvasContractTests
```

Expected: compile failures for model and state API.

- [ ] **Step 3: Add validated rectangular canvas configuration**

Introduce one immutable renderer configuration:

```swift
public struct TilingCanvasConfiguration: Equatable, Sendable {
    public let pixelSize: PixelSize
    public let tiling: TilingKind

    public init(pixelSize: PixelSize, tiling: TilingKind) throws
}
```

Reject width/height outside `64...4096` with
`.invalidTileDimensions(width:height:)`. Use width and height independently in
canonical, scratch, live, viewport center, uniforms, copy, commit, and harness
validation.

- [ ] **Step 4: Implement idle-only renderer tiling state**

`setTiling` checks lifecycle first, then replaces the immutable strategy value.
It must not allocate textures, clear live/canonical content, mutate raster
revision, or replay strokes. Expose an idle-state callback for app enablement;
the renderer remains the authority when a UI event races pointer input.

- [ ] **Step 5: Add the minimal `EditorModel` and app dependency**

Import `Observation` and `PatternEngine` only. Add `EditorCore` to both app
target dependencies in `App/project.yml`. Keep platform types out of
`EditorCore`.

- [ ] **Step 6: Add the native tiling selector**

Place one compact `Picker` over the canvas. Its binding must:

1. request `renderer.setTiling(candidate)`;
2. call `model.confirmTiling(candidate)` only after success;
3. leave selection unchanged and show the typed error after rejection.

Disable it while the renderer reports non-idle. Do not add any other toolbar
or inspector behavior.

- [ ] **Step 7: Add and prove remaining behavior scene pairs**

Add:

- `rectangular-tile` using `320 x 192`;
- `noncentral-visible-cell-{grid,halfdrop,brick,mirror-x,mirror-y,mirror-xy,rotational}`;
- `metadata-tiling-switch`;
- `projected-live-commit`;
- `projected-long-stroke`.

Each noncentral scene renders the same fixed stroke once through the central
cell and once through a parity-distinct visible cell for its tiling, captures
both canonical rasters from pristine renderers, and asserts byte delta `0`.
Half-drop, brick, and mirrors choose an odd phased/reflected cell; rotational
chooses a translated cell and validates its p2 image pair.

The switch scene captures screen, canonical bytes, and revision before
`grid -> mirrorXY -> grid`; assert canonical byte delta `0`, revision delta
`0`, changed display pixels while mirror is active, and restored-screen
maximum delta `0` after returning to grid. The long scene requires
`restampedInstanceCount == 0`.

- [ ] **Step 8: Verify minimum and maximum resource boundaries**

Run a `64 x 64` real-Metal scene. Construct and clear `4096 x 64` and
`64 x 4096` renderer resources in separate harness invocations, then release
them; do not claim a simultaneous `4096 x 4096` performance baseline.

- [ ] **Step 9: Run all tests and both builds**

Run:

```bash
swift test
(cd App && xcodegen generate)
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac -configuration Debug build
xcodebuild -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
! rg -n 'import (SwiftUI|AppKit|UIKit|Metal|MetalKit)' Sources/EditorCore
```

Expected: all pass; dependency audit prints nothing.

Run:

```bash
run_pair rectangular-tile grid oracleHoleCount
run_pair noncentral-visible-cell-grid grid visibleCellCanonicalByteDelta
run_pair noncentral-visible-cell-halfdrop halfDrop visibleCellCanonicalByteDelta
run_pair noncentral-visible-cell-brick brick visibleCellCanonicalByteDelta
run_pair noncentral-visible-cell-mirror-x mirrorX visibleCellCanonicalByteDelta
run_pair noncentral-visible-cell-mirror-y mirrorY visibleCellCanonicalByteDelta
run_pair noncentral-visible-cell-mirror-xy mirrorXY visibleCellCanonicalByteDelta
run_pair noncentral-visible-cell-rotational rotational visibleCellCanonicalByteDelta
run_pair metadata-tiling-switch grid canonicalByteDelta
run_pair projected-live-commit halfDrop previewCommitViolationCount
run_pair projected-long-stroke halfDrop restampedInstanceCount
```

Expected: eleven exact negative failures followed by eleven positive passes.

- [ ] **Step 10: Run the manual state smoke**

On Mac verify all seven selector values, central/noncentral drawing, rejected
active-stroke changes, pan, cursor-anchored zoom, resize, cancel, stroke
direction, and cursor alignment. This is a smoke only; final acceptance is
Task 10.

- [ ] **Step 11: Review and commit**

Review resource dimensions, canonical byte identity, fail-closed app ordering,
UI scope, and iPad compilation. After approval:

```bash
git add Sources/EditorCore/Model/EditorModel.swift \
  Tests/EditorCoreTests/EditorModelTests.swift \
  Sources/MetalRenderer/GridCanvasContract.swift \
  Sources/MetalRenderer/GridRenderer.swift \
  Sources/MetalRenderer/MetalRendererError.swift \
  Sources/MetalRenderer/Capture/HarnessRunner.swift \
  Tests/MetalRendererTests/GridCanvasContractTests.swift \
  App/project.yml \
  App/PatternSpike/ContentView.swift \
  App/PatternSpike/Canvas/MetalCanvas.swift \
  App/PatternSpike/Harness/Scenes/rectangular-tile.json \
  App/PatternSpike/Harness/Scenes/rectangular-tile-negative-control.json \
  App/PatternSpike/Harness/Scenes/noncentral-visible-cell-grid.json \
  App/PatternSpike/Harness/Scenes/noncentral-visible-cell-grid-negative-control.json \
  App/PatternSpike/Harness/Scenes/noncentral-visible-cell-halfdrop.json \
  App/PatternSpike/Harness/Scenes/noncentral-visible-cell-halfdrop-negative-control.json \
  App/PatternSpike/Harness/Scenes/noncentral-visible-cell-brick.json \
  App/PatternSpike/Harness/Scenes/noncentral-visible-cell-brick-negative-control.json \
  App/PatternSpike/Harness/Scenes/noncentral-visible-cell-mirror-x.json \
  App/PatternSpike/Harness/Scenes/noncentral-visible-cell-mirror-x-negative-control.json \
  App/PatternSpike/Harness/Scenes/noncentral-visible-cell-mirror-y.json \
  App/PatternSpike/Harness/Scenes/noncentral-visible-cell-mirror-y-negative-control.json \
  App/PatternSpike/Harness/Scenes/noncentral-visible-cell-mirror-xy.json \
  App/PatternSpike/Harness/Scenes/noncentral-visible-cell-mirror-xy-negative-control.json \
  App/PatternSpike/Harness/Scenes/noncentral-visible-cell-rotational.json \
  App/PatternSpike/Harness/Scenes/noncentral-visible-cell-rotational-negative-control.json \
  App/PatternSpike/Harness/Scenes/metadata-tiling-switch.json \
  App/PatternSpike/Harness/Scenes/metadata-tiling-switch-negative-control.json \
  App/PatternSpike/Harness/Scenes/projected-live-commit.json \
  App/PatternSpike/Harness/Scenes/projected-live-commit-negative-control.json \
  App/PatternSpike/Harness/Scenes/projected-long-stroke.json \
  App/PatternSpike/Harness/Scenes/projected-long-stroke-negative-control.json
git commit -m "feat: add pixel-safe tiling selection"
```

---

### Task 9: Complete Negative-First Scene Matrix And Diagnostics

**Files:**
- Modify: `Sources/MetalRenderer/Capture/HarnessScene.swift`
- Modify: `Sources/MetalRenderer/Capture/HarnessRunner.swift`
- Modify: `Sources/MetalRenderer/BenchmarkRecord.swift`
- Modify: `Tests/MetalRendererTests/HarnessSceneTests.swift`
- Modify: `Tests/MetalRendererTests/BenchmarkRecordTests.swift`
- Verify every Slice 2 scene pair in File Map

- [ ] **Step 1: Audit scene coverage mechanically**

Run:

```bash
for positive in \
  generalized-grid \
  halfdrop-interior halfdrop-edge halfdrop-corner brick-transpose \
  mirror-x mirror-y mirror-xy \
  rotational-generator rotational-fixed-point rotational-orientation \
  large-footprint asymmetric-footprint \
  canonical-coordinate-continuity brush-local-coordinate-continuity \
  rectangular-tile \
  noncentral-visible-cell-grid noncentral-visible-cell-halfdrop \
  noncentral-visible-cell-brick noncentral-visible-cell-mirror-x \
  noncentral-visible-cell-mirror-y noncentral-visible-cell-mirror-xy \
  noncentral-visible-cell-rotational metadata-tiling-switch \
  projected-live-commit projected-long-stroke
do
  test -f "App/PatternSpike/Harness/Scenes/$positive.json"
  test -f \
    "App/PatternSpike/Harness/Scenes/$positive-negative-control.json"
done
```

Expected: exit `0`.

- [ ] **Step 2: Add failing benchmark-schema tests**

Append, without removing Slice 1 fields:

- tiling raw value;
- tile width/height;
- total projected fragment count;
- maximum fragments for one footprint;
- total instance bytes;
- oracle hole/phantom/max-delta;
- diagnostic mode.
- long-stroke early/late CPU p95, early/late dab-GPU p95, and least-squares
  milliseconds-per-frame slopes.

Assert old schema 1/2 benchmark JSON still decodes.

- [ ] **Step 3: Add exact structural invariants**

Harness execution must fail if:

- a generated fragment exceeds four planes;
- encoded instances exceed fixed pending capacity;
- fragment order changes across identical runs;
- any old instance is restamped;
- the fixed long-stroke program does not emit the same projected-instance
  count in each measured early/late frame;
- tiling switch changes canonical bytes or revision;
- preview/commit maximum delta exceeds `1`;
- oracle holes or phantoms are nonzero;
- diagnostic pipelines are requested by an interactive program.

The long-stroke timing program uses 400 equal-length horizontal input segments
whose measured frames each emit the same projected-instance count. Compare
frames `40...119` with `280...359`. Require both late CPU and late dab-GPU p95
to be no greater than `max(earlyP95 * 1.15, earlyP95 + 0.10 ms)`, and require
the least-squares slope for each series to be `<= 0.001 ms/frame`.

Use this fixed scene matrix. The negative scene changes only the listed metric
from expected `0` to expected `1`; correct output therefore has actual `0`.
All hard-round inputs use radius `10` except `large-footprint`, which uses the
approved clamped radius `256`.

Every matrix JSON uses schema `3`, drawable `512 x 512`, the table's tile and
numeric tiling raw value, the table's diagnostic string, `checks: []`, and
these positive structural checks:

```json
[
  {"metric": "<negative metric>", "relation": "equal", "value": 0},
  {"metric": "oracleHoleCount", "relation": "equal", "value": 0},
  {"metric": "oraclePhantomCount", "relation": "equal", "value": 0},
  {"metric": "oracleMaximumDelta", "relation": "lessThanOrEqual", "value": 1}
]
```

For non-coverage state programs, omit the three oracle checks and keep the
listed metric at zero. The paired negative changes only that first value to
`1`. Program raw values are the `TilingHarnessProgram` cases above:
translation/mirror/rotational/diagnostic/rectangular scenes use the matching
camel-case case; all seven noncentral scenes use `noncentralVisibleCell`;
the last three use `metadataTilingSwitch`, `projectedLiveCommit`, and
`projectedLongStroke`. The `halfdrop-edge` pair retains its additional exact
canonical pixel check from Task 6.

| Positive scene | Tiling | Tile | Diagnostic | Fixed program/input | Negative metric |
| --- | --- | --- | --- | --- | --- |
| generalized-grid | grid | 256x256 | hardRound | center `(-2,-2)` | oracleHoleCount |
| halfdrop-interior | halfDrop | 288x192 | hardRound | center `(432,144)` | oraclePhantomCount |
| halfdrop-edge | halfDrop | 288x192 | hardRound | center `(288,96)` | oracleHoleCount |
| halfdrop-corner | halfDrop | 288x192 | hardRound | center `(288,288)` | oraclePhantomCount |
| brick-transpose | brick | 288x192 | hardRound | center `(144,192)` | transformMismatchCount |
| mirror-x | mirrorX | 256x256 | asymmetricCoverage | center `(256,96)` | transformMismatchCount |
| mirror-y | mirrorY | 256x256 | asymmetricCoverage | center `(96,256)` | transformMismatchCount |
| mirror-xy | mirrorXY | 256x256 | asymmetricCoverage | center `(256,256)` | transformMismatchCount |
| rotational-generator | rotational | 256x256 | asymmetricCoverage | center `(64,80)` | transformMismatchCount |
| rotational-fixed-point | rotational | 256x256 | hardRound | center `(128,128)` | duplicateFixedPointWriteCount |
| rotational-orientation | rotational | 256x256 | asymmetricCoverage | center `(64,80)` | transformMismatchCount |
| large-footprint | grid | 64x96 | hardRound | center `(0,0)`, radius `256` | oracleHoleCount |
| asymmetric-footprint | rotational | 256x256 | asymmetricCoverage | center `(250,128)`, rotation `0.37` | transformMismatchCount |
| canonical-coordinate-continuity | halfDrop | 288x192 | canonicalCoordinates | center `(288,96)`, scale `40` | coordinateContinuityMismatchCount |
| brush-local-coordinate-continuity | mirrorXY | 256x256 | brushLocalCoordinates | center `(256,256)`, scale `40` | coordinateContinuityMismatchCount |
| rectangular-tile | grid | 320x192 | hardRound | center `(318,190)` | oracleHoleCount |
| noncentral-visible-cell-grid | grid | 256x256 | hardRound | central `(64,64)`, repeat `(320,64)` | visibleCellCanonicalByteDelta |
| noncentral-visible-cell-halfdrop | halfDrop | 288x192 | hardRound | central `(64,64)`, repeat `(352,160)` | visibleCellCanonicalByteDelta |
| noncentral-visible-cell-brick | brick | 288x192 | hardRound | central `(64,64)`, repeat `(208,256)` | visibleCellCanonicalByteDelta |
| noncentral-visible-cell-mirror-x | mirrorX | 256x256 | hardRound | central `(64,64)`, repeat `(448,64)` | visibleCellCanonicalByteDelta |
| noncentral-visible-cell-mirror-y | mirrorY | 256x256 | hardRound | central `(64,64)`, repeat `(64,448)` | visibleCellCanonicalByteDelta |
| noncentral-visible-cell-mirror-xy | mirrorXY | 256x256 | hardRound | central `(64,64)`, repeat `(448,448)` | visibleCellCanonicalByteDelta |
| noncentral-visible-cell-rotational | rotational | 256x256 | hardRound | central `(64,80)`, repeat `(320,80)` | visibleCellCanonicalByteDelta |
| metadata-tiling-switch | grid -> mirrorXY -> grid | 256x256 | hardRound | committed center `(64,64)` | canonicalByteDelta |
| projected-live-commit | halfDrop | 288x192 | hardRound | stroke `(278,90)->(298,110)` | previewCommitViolationCount |
| projected-long-stroke | halfDrop | 288x192 | hardRound | 400 equal 32px segments | restampedInstanceCount |

Use one exact runner for every row:

```bash
binary=".build/DerivedData/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike"
scenes="App/PatternSpike/Harness/Scenes"
artifacts=".build/slice2-artifacts"
commit="$(git rev-parse HEAD)"

run_pair() {
  name="$1"
  tiling="$2"
  metric="$3"
  negative="$name-negative-control"
  negative_output="$artifacts/negative-control/$negative"
  positive_output="$artifacts/positive/$name"
  mkdir -p "$negative_output" "$positive_output"

  if "$binary" \
    --harness-scene "$scenes/$negative.json" \
    --output-directory "$negative_output" \
    --git-commit "$commit" \
    --configuration Debug \
    >"$negative_output/stdout.log" \
    2>"$negative_output/stderr.log"
  then
    printf 'Negative control unexpectedly passed: %s\n' "$negative"
    return 1
  fi
  expected="HARNESS FAIL Tiling scene '$negative' tiling $tiling cell none metric $metric: expected equal 1, actual 0."
  grep -Fqx "$expected" "$negative_output/stderr.log"

  "$binary" \
    --harness-scene "$scenes/$name.json" \
    --output-directory "$positive_output" \
    --git-commit "$commit" \
    --configuration Debug \
    | tee "$positive_output/stdout.log"
  grep -q "^HARNESS PASS scene=$name " "$positive_output/stdout.log"
  test -s "$positive_output/$name.benchmark.json"
}
```

- [ ] **Step 4: Prove every negative control before its positive**

For every matrix row, call `run_pair` with its exact scene, tiling display
name, and metric. Run the calls in table order. The negative must fail with
the complete typed stderr line before the positive may run. Require:

```text
HARNESS PASS scene=<scene-name>
```

- [ ] `run_pair generalized-grid grid oracleHoleCount`
- [ ] `run_pair halfdrop-interior halfDrop oraclePhantomCount`
- [ ] `run_pair halfdrop-edge halfDrop oracleHoleCount`
- [ ] `run_pair halfdrop-corner halfDrop oraclePhantomCount`
- [ ] `run_pair brick-transpose brick transformMismatchCount`
- [ ] `run_pair mirror-x mirrorX transformMismatchCount`
- [ ] `run_pair mirror-y mirrorY transformMismatchCount`
- [ ] `run_pair mirror-xy mirrorXY transformMismatchCount`
- [ ] `run_pair rotational-generator rotational transformMismatchCount`
- [ ] `run_pair rotational-fixed-point rotational duplicateFixedPointWriteCount`
- [ ] `run_pair rotational-orientation rotational transformMismatchCount`
- [ ] `run_pair large-footprint grid oracleHoleCount`
- [ ] `run_pair asymmetric-footprint rotational transformMismatchCount`
- [ ] `run_pair canonical-coordinate-continuity halfDrop coordinateContinuityMismatchCount`
- [ ] `run_pair brush-local-coordinate-continuity mirrorXY coordinateContinuityMismatchCount`
- [ ] `run_pair rectangular-tile grid oracleHoleCount`
- [ ] `run_pair noncentral-visible-cell-grid grid visibleCellCanonicalByteDelta`
- [ ] `run_pair noncentral-visible-cell-halfdrop halfDrop visibleCellCanonicalByteDelta`
- [ ] `run_pair noncentral-visible-cell-brick brick visibleCellCanonicalByteDelta`
- [ ] `run_pair noncentral-visible-cell-mirror-x mirrorX visibleCellCanonicalByteDelta`
- [ ] `run_pair noncentral-visible-cell-mirror-y mirrorY visibleCellCanonicalByteDelta`
- [ ] `run_pair noncentral-visible-cell-mirror-xy mirrorXY visibleCellCanonicalByteDelta`
- [ ] `run_pair noncentral-visible-cell-rotational rotational visibleCellCanonicalByteDelta`
- [ ] `run_pair metadata-tiling-switch grid canonicalByteDelta`
- [ ] `run_pair projected-live-commit halfDrop previewCommitViolationCount`
- [ ] `run_pair projected-long-stroke halfDrop restampedInstanceCount`

Retain live screen, committed screen, canonical, oracle coverage, and benchmark
artifacts whenever the family produces them.

- [ ] **Step 5: Re-run legacy schema and Slice 1 regressions**

Run:

```bash
swift test
PATTERN_SKIP_PERFORMANCE=1 ./scripts/verify-slice1.sh
```

Expected: all legacy tests/scenes pass and no old JSON file changes.

- [ ] **Step 6: Review and commit**

Review the final matrix against spec section 10 and verify each family has one
specific negative proof. After approval:

```bash
git add Sources/MetalRenderer/Capture/HarnessScene.swift \
  Sources/MetalRenderer/Capture/HarnessRunner.swift \
  Sources/MetalRenderer/BenchmarkRecord.swift \
  Tests/MetalRendererTests/HarnessSceneTests.swift \
  Tests/MetalRendererTests/BenchmarkRecordTests.swift
git commit -m "test: complete Slice 2 GPU matrix"
```

---

### Task 10: Automated Gate, Performance, Manual Acceptance, And Milestone

**Files:**
- Create: `scripts/verify-slice2.sh`
- Create:
  `docs/superpowers/milestones/02-generalized-seam-correct-tiling.md`

- [ ] **Step 1: Build the negative-first automated gate**

`verify-slice2.sh` must:

1. run `PATTERN_SKIP_PERFORMANCE=1 scripts/verify-slice1.sh`;
2. run `swift test`;
3. generate the Xcode project;
4. build macOS Debug and generic iPadOS Simulator;
5. run every Slice 2 negative control and match its exact stderr;
6. run every positive and require its artifacts;
7. evaluate correctness/structural/performance JSON;
8. prove generated artifacts remain ignored;
9. print one final pass line.

Do not duplicate renderer logic in the shell script.

- [ ] **Step 2: Add fixed performance checks**

Require:

- brush processing p95 `< 2 ms/frame`;
- 500-new-dab GPU maximum `< 3 ms`;
- tiling display p95 `< 2 ms`;
- missed-frame fraction `< 0.01`;
- late long-stroke frames encode zero old instances;
- long-stroke late CPU/dab-GPU p95 is at most
  `max(earlyP95 * 1.15, earlyP95 + 0.10 ms)`;
- long-stroke CPU and dab-GPU slopes are each `<= 0.001 ms/frame`;
- when a stable accepted Slice 1 baseline exists on matching hardware, OS, and
  configuration, no unexplained p95 regression greater than `15%`.

When an accepted baseline exists, preserve it outside the mutable
`.build/slice1-artifacts` directory, write a checksum manifest, and invoke:

```bash
baseline_root="$(cat .build/accepted-baselines/current-slice1)"
(
  cd "$baseline_root"
  shasum -a 256 -c SHA256SUMS
)
SLICE1_BASELINE_DIR="$baseline_root/positive" \
  ./scripts/verify-slice2.sh
```

If no accepted baseline exists, invoke `./scripts/verify-slice2.sh` without
`SLICE1_BASELINE_DIR`; the absolute Slice 2 budgets remain mandatory and the
milestone records `slice1Comparison: unavailable-user-waived`. If a baseline
is supplied but hardware, OS, or configuration differs, fail with a typed
baseline mismatch instead of comparing incomparable timings.
`verify-slice2.sh` rejects a supplied baseline path under mutable
`.build/slice1-artifacts` and verifies its immutable checksum manifest before
and after its internal Slice 1 functional regression run.

- [ ] **Step 3: Run the complete automated gate**

Expected final lines:

```text
slice0-regression=passed
slice1-regression=passed
slice2-negative-controls=passed
slice2-positive-scenes=passed
SLICE2 AUTOMATED GATE PASS
```

- [ ] **Step 4: Run the final manual Mac gate**

Record:

- all seven repeats look correct;
- central and noncentral drawing edit identical canonical content;
- half-drop/brick edges and corners have no holes or phantom copies;
- mirror and p2 asymmetric orientation is correct;
- tiling changes alter display without altering canonical pixels;
- preview/commit and cancel are visually stable;
- pan, cursor-anchored zoom, resize, stroke direction, and pointer alignment
  remain correct;
- long projected strokes remain responsive.

- [ ] **Step 5: Write the measured milestone**

Record exact commit, GPU, OS, configuration, artifact paths, tile sizes,
tilings, diagnostic modes, fragment counts, instance bytes, CPU spans, GPU
spans, frames, missed frames, memory, oracle results, negative-control
failures, manual checklist, decisions, and retrospective. Mark it `Accepted`
only after automated, performance, and manual gates all pass.

- [ ] **Step 6: Run final scope and hygiene audits**

Run:

```bash
! rg -n 'GridProjection|CanonicalDabPlacement' Sources Tests
! rg -n 'import (Metal|MetalKit|SwiftUI|AppKit|UIKit|Observation)' \
  Sources/PatternEngine
! rg -n 'import (SwiftUI|AppKit|UIKit|Metal|MetalKit)' Sources/EditorCore
! git ls-files --error-unmatch App/PatternSpike.xcodeproj
test -z "$(git status --short -- .build App/PatternSpike.xcodeproj)"
git diff --check
git status --short
```

The `git ls-files` command is expected to exit `1`; every other check exits
`0`, and status contains only the milestone/gate changes intended for commit.

- [ ] **Step 7: Request final review and commit**

Use `superpowers:requesting-code-review` against the complete Slice 2 diff and
both approved specs. Resolve findings and re-run `verify-slice2.sh`. Then:

```bash
git add scripts/verify-slice2.sh \
  docs/superpowers/milestones/02-generalized-seam-correct-tiling.md
git commit -m "docs: accept generalized tiling slice"
git push origin main
```

---

## Final Acceptance Checklist

- [ ] The explicit Slice 1 performance-gate override is recorded, and its
  functional regression gate remains green.
- [ ] All seven tilings use `TilingProjection`; no production grid shortcut
  remains.
- [ ] CPU oracle implementation is source-level independent.
- [ ] Oracle and real Metal report zero holes and zero phantoms.
- [ ] Large, rotated, reflected, asymmetric, and rectangular cases pass.
- [ ] Drawing through a noncentral repeat edits the same canonical content.
- [ ] Tiling switching changes no canonical byte or revision.
- [ ] Returning to a prior tiling restores the exact prior screen rendering.
- [ ] Live/commit maximum delta is at most one 8-bit value.
- [ ] Cancel and renderer failure preserve the last committed state.
- [ ] Long strokes encode only newly projected fragments.
- [ ] ABI sizes, offsets, raw values, and indices match exactly.
- [ ] Legacy Slice 0/1 scenes and both app builds remain green.
- [ ] Slice 2 performance stays inside fixed absolute budgets; the 15-percent
  Slice 1 comparison passes when a stable accepted baseline is available, or
  its user-waived absence is recorded.
- [ ] Manual Mac acceptance is recorded.
- [ ] No Slice 3 behavior entered scope.
- [ ] The measured Slice 2 milestone is marked `Accepted` and pushed.
